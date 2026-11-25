#!/usr/bin/env python3
"""Add PIT (with XML output) and JaCoCo to a Maven pom.xml, idempotently.

The guard refuses a PIT report it cannot parse, so the XML output format is not
optional. Rather than asking a person to paste XML into every service, this adds
it in place and can be re-run safely.

Detection is done with a real XML parser. Writing is done by inserting text at a
known offset, so the rest of the file keeps its formatting, comments and
ordering. The file is never reserialised.

Usage:
  setup_pom.py --check [POM]        report what is missing; exit 1 if incomplete
  setup_pom.py --dry-run [POM]      print the unified diff, write nothing
  setup_pom.py [POM]                patch in place (writes POM.bak first)

Options:
  --pitest-version X        default 1.30.2
  --junit5-plugin-version X default 1.2.3
  --jacoco-version X        default 0.8.12
  --no-jacoco               PIT only
  --force                   patch even when <modules> suggests an aggregator pom

Exit codes: 0 ok / already configured, 1 incomplete (--check) or failed, 2 bad input.
"""
import argparse
import difflib
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = "http://maven.apache.org/POM/4.0.0"
DEFAULT_PITEST = "1.30.2"
DEFAULT_JUNIT5_PLUGIN = "1.2.3"
DEFAULT_JACOCO = "0.8.12"


def strip_ns(tag):
    return tag.split("}", 1)[1] if "}" in tag else tag


def find(parent, name):
    for c in parent:
        if strip_ns(c.tag) == name:
            return c
    return None


def findall(parent, name):
    return [c for c in parent if strip_ns(c.tag) == name]


def text_of(parent, name):
    el = find(parent, name)
    return (el.text or "").strip() if el is not None else None


class Pom:
    def __init__(self, path: Path):
        self.path = path
        self.raw = path.read_text(encoding="utf-8")
        try:
            self.root = ET.fromstring(self.raw)
        except ET.ParseError as e:
            raise SystemExit(f"ERROR: {path} is not valid XML: {e}")
        if strip_ns(self.root.tag) != "project":
            raise SystemExit(f"ERROR: {path} root element is not <project>")
        self.indent = self._detect_indent()

    def _detect_indent(self):
        for line in self.raw.splitlines():
            m = re.match(r"^([ \t]+)<", line)
            if m:
                return m.group(1)
        return "  "

    # ---------------------------------------------------------------- queries
    def is_aggregator(self):
        return find(self.root, "modules") is not None

    def plugins(self):
        build = find(self.root, "build")
        if build is None:
            return []
        plugins = find(build, "plugins")
        return list(plugins) if plugins is not None else []

    def plugin(self, group, artifact):
        for p in self.plugins():
            if strip_ns(p.tag) != "plugin":
                continue
            g = text_of(p, "groupId")
            a = text_of(p, "artifactId")
            if a == artifact and (g == group or g is None):
                return p
        return None

    def pitest_has_xml(self):
        p = self.plugin("org.pitest", "pitest-maven")
        if p is None:
            return False
        cfg = find(p, "configuration")
        if cfg is None:
            return False
        fmts = find(cfg, "outputFormats")
        if fmts is None:
            return False
        return any((c.text or "").strip().upper() == "XML" for c in fmts)

    def uses_junit5(self):
        """JUnit 5 needs pitest-junit5-plugin on PIT's own classpath."""
        markers = ("junit-jupiter", "spring-boot-starter-test", "junit-platform")
        return any(m in self.raw for m in markers)

    def status(self):
        pit = self.plugin("org.pitest", "pitest-maven")
        jac = self.plugin("org.jacoco", "jacoco-maven-plugin")
        return {
            "pitest": pit is not None,
            "pitest_xml": self.pitest_has_xml(),
            "jacoco": jac is not None,
            "junit5": self.uses_junit5(),
            "aggregator": self.is_aggregator(),
        }

    # ---------------------------------------------------------------- writing
    def _plugins_insert_offset(self):
        """Byte offset just inside <build><plugins>, creating them if needed.

        Returns (offset, prefix, suffix) where prefix/suffix wrap the plugin XML.
        """
        build = find(self.root, "build")
        i = self.indent
        if build is not None and find(build, "plugins") is not None:
            m = re.search(r"<plugins\s*>", self.raw)
            if m:
                return m.end(), "\n", ""
        if build is not None:
            m = re.search(r"<build\s*>", self.raw)
            if m:
                return m.end(), f"\n{i}{i}<plugins>\n", f"\n{i}{i}</plugins>"
        # no <build> at all: insert before </project>
        m = re.search(r"</project\s*>\s*$", self.raw)
        if not m:
            raise SystemExit("ERROR: could not find </project>")
        return m.start(), f"\n{i}<build>\n{i}{i}<plugins>\n", f"\n{i}{i}</plugins>\n{i}</build>\n\n"

    def pitest_xml(self, pitest_version, junit5_version, add_junit5):
        i = self.indent
        p = i * 3  # plugin element indent inside build/plugins
        dep = ""
        if add_junit5:
            dep = (
                f"\n{p}{i}<dependencies>\n"
                f"{p}{i}{i}<dependency>\n"
                f"{p}{i}{i}{i}<groupId>org.pitest</groupId>\n"
                f"{p}{i}{i}{i}<artifactId>pitest-junit5-plugin</artifactId>\n"
                f"{p}{i}{i}{i}<version>{junit5_version}</version>\n"
                f"{p}{i}{i}</dependency>\n"
                f"{p}{i}</dependencies>"
            )
        return (
            f"{p}<!-- Mutation testing. XML output is REQUIRED: scripts/pit_score.py\n"
            f"{p}     parses it, and the guard fails rather than guess without it. -->\n"
            f"{p}<plugin>\n"
            f"{p}{i}<groupId>org.pitest</groupId>\n"
            f"{p}{i}<artifactId>pitest-maven</artifactId>\n"
            f"{p}{i}<version>{pitest_version}</version>\n"
            f"{p}{i}<configuration>\n"
            f"{p}{i}{i}<outputFormats>\n"
            f"{p}{i}{i}{i}<outputFormat>XML</outputFormat>\n"
            f"{p}{i}{i}{i}<outputFormat>HTML</outputFormat>\n"
            f"{p}{i}{i}</outputFormats>\n"
            f"{p}{i}{i}<timestampedReports>false</timestampedReports>\n"
            f"{p}{i}</configuration>{dep}\n"
            f"{p}</plugin>\n"
        )

    def jacoco_xml(self, version):
        i = self.indent
        p = i * 3
        return (
            f"{p}<!-- Branch coverage. Reported, never used as a quality gate on\n"
            f"{p}     its own: lines executed is not behaviour verified. -->\n"
            f"{p}<plugin>\n"
            f"{p}{i}<groupId>org.jacoco</groupId>\n"
            f"{p}{i}<artifactId>jacoco-maven-plugin</artifactId>\n"
            f"{p}{i}<version>{version}</version>\n"
            f"{p}{i}<executions>\n"
            f"{p}{i}{i}<execution>\n"
            f"{p}{i}{i}{i}<id>prepare-agent</id>\n"
            f"{p}{i}{i}{i}<goals><goal>prepare-agent</goal></goals>\n"
            f"{p}{i}{i}</execution>\n"
            f"{p}{i}{i}<execution>\n"
            f"{p}{i}{i}{i}<id>report</id>\n"
            f"{p}{i}{i}{i}<phase>verify</phase>\n"
            f"{p}{i}{i}{i}<goals><goal>report</goal></goals>\n"
            f"{p}{i}{i}</execution>\n"
            f"{p}{i}</executions>\n"
            f"{p}</plugin>\n"
        )

    def add_xml_to_existing_pitest(self):
        """PIT is present but has no XML output format. Patch just that."""
        m = re.search(r"(<artifactId>\s*pitest-maven\s*</artifactId>)", self.raw)
        if not m:
            return None
        # locate this plugin's <configuration>...</configuration>, if any
        tail = self.raw[m.end():]
        cfg = re.search(r"<configuration\s*>", tail)
        fmts = re.search(r"<outputFormats\s*>", tail)
        i = self.indent
        if fmts and (not cfg or fmts.start() < tail.find("</plugin>")):
            # outputFormats exists but lacks XML: add the element
            at = m.end() + fmts.end()
            return self.raw[:at] + f"\n{i*5}<outputFormat>XML</outputFormat>" + self.raw[at:]
        if cfg and cfg.start() < tail.find("</plugin>"):
            at = m.end() + cfg.end()
            block = (f"\n{i*5}<outputFormats>\n"
                     f"{i*6}<outputFormat>XML</outputFormat>\n"
                     f"{i*6}<outputFormat>HTML</outputFormat>\n"
                     f"{i*5}</outputFormats>")
            return self.raw[:at] + block + self.raw[at:]
        # no configuration element: add one right after the artifactId line
        at = m.end()
        block = (f"\n{i*4}<configuration>\n"
                 f"{i*5}<outputFormats>\n"
                 f"{i*6}<outputFormat>XML</outputFormat>\n"
                 f"{i*6}<outputFormat>HTML</outputFormat>\n"
                 f"{i*5}</outputFormats>\n"
                 f"{i*4}</configuration>")
        return self.raw[:at] + block + self.raw[at:]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("pom", nargs="?", default="pom.xml")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--pitest-version", default=DEFAULT_PITEST)
    ap.add_argument("--junit5-plugin-version", default=DEFAULT_JUNIT5_PLUGIN)
    ap.add_argument("--jacoco-version", default=DEFAULT_JACOCO)
    ap.add_argument("--no-jacoco", action="store_true")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()

    path = Path(a.pom)
    if not path.exists():
        print(f"ERROR: {path} not found. Run this from the service repo root, "
              "or pass the path to its pom.xml.", file=sys.stderr)
        return 2

    pom = Pom(path)
    st = pom.status()

    if a.check:
        need = []
        if not st["pitest"]:
            need.append("pitest-maven plugin")
        elif not st["pitest_xml"]:
            need.append("XML output format on pitest-maven (the guard cannot score without it)")
        if not st["jacoco"] and not a.no_jacoco:
            need.append("jacoco-maven-plugin")
        if need:
            print("INCOMPLETE: " + "; ".join(need), file=sys.stderr)
            print(f"Run: python {sys.argv[0]} {path}", file=sys.stderr)
            return 1
        print("OK: pitest with XML output present" + ("" if a.no_jacoco else ", jacoco present"))
        return 0

    if st["aggregator"] and not a.force:
        print(f"REFUSED: {path} declares <modules>, so it looks like an aggregator pom. "
              "PIT must be configured on the modules that hold the code. Run this against "
              "each module's pom.xml, or pass --force if you know this is right.",
              file=sys.stderr)
        return 2

    new = pom.raw
    actions = []

    if st["pitest"] and st["pitest_xml"]:
        actions.append("pitest: already has XML output, unchanged")
    elif st["pitest"]:
        patched = Pom.add_xml_to_existing_pitest(pom)
        if patched is None:
            print("ERROR: pitest-maven is present but its XML could not be patched. "
                  "Add <outputFormat>XML</outputFormat> by hand.", file=sys.stderr)
            return 1
        new = patched
        actions.append("pitest: added XML to the existing plugin")
    else:
        off, pre, post = pom._plugins_insert_offset()
        block = pom.pitest_xml(a.pitest_version, a.junit5_plugin_version, st["junit5"])
        new = new[:off] + pre + block + post + new[off:]
        actions.append(f"pitest: added v{a.pitest_version}" +
                       (f" with pitest-junit5-plugin v{a.junit5_plugin_version}" if st["junit5"] else ""))

    if not a.no_jacoco and not st["jacoco"]:
        pom2 = Pom.__new__(Pom)
        pom2.path, pom2.raw, pom2.indent = path, new, pom.indent
        pom2.root = ET.fromstring(new)
        off, pre, post = pom2._plugins_insert_offset()
        new = new[:off] + pre + pom.jacoco_xml(a.jacoco_version) + post + new[off:]
        actions.append(f"jacoco: added v{a.jacoco_version}")
    elif not a.no_jacoco:
        actions.append("jacoco: already present, unchanged")

    if new == pom.raw:
        print("Nothing to do:")
        for x in actions:
            print(f"  {x}")
        return 0

    try:
        ET.fromstring(new)
    except ET.ParseError as e:
        print(f"ERROR: the patched pom would not be valid XML ({e}). Nothing written.",
              file=sys.stderr)
        return 1

    if a.dry_run:
        sys.stdout.writelines(difflib.unified_diff(
            pom.raw.splitlines(keepends=True), new.splitlines(keepends=True),
            fromfile=str(path), tofile=f"{path} (patched)"))
        print("\n(dry run: nothing written)")
        return 0

    shutil.copy2(path, str(path) + ".bak")
    path.write_text(new, encoding="utf-8")
    for x in actions:
        print(f"  {x}")
    print(f"Wrote {path} (backup at {path}.bak)")
    print("Verify the pinned versions against Maven Central before committing.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # piping into head/less closes stdout early; that is not an error
        try:
            sys.stdout.close()
        finally:
            sys.exit(0)
