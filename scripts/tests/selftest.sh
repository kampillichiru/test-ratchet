#!/usr/bin/env bash
# Self-test for the harness. Needs bash, git and Python only; no Maven.
#
# Every case named GAP-n is a regression test for a hole that was found by
# attacking the first version of this harness. If one of these fails, the
# harness is back to grading its own work.
#
# Usage: bash scripts/tests/selftest.sh
set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/../.." && pwd)
GUARD="$HARNESS/scripts/test-guard.sh"
HOOK="$HARNESS/scripts/hooks/block_main_edits.py"
CENSUS="$HARNESS/scripts/test_census.py"
PITS="$HARNESS/scripts/pit_score.py"
APPROVAL="$HARNESS/scripts/approval.py"
PY=$(command -v python3 || command -v python)

pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1 — $2"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }

# ---------------------------------------------------------------- hook cases
hook() { printf '%s' "$3" | "$PY" "$HOOK" >/dev/null 2>&1; check "$1" "$2" "$?"; }

echo "== hook: production code =="
hook "Edit to src/main is blocked"                 2 '{"tool_name":"Edit","tool_input":{"file_path":"src/main/java/demo/A.java"}}'
hook "Windows-path src\\main is blocked"           2 '{"tool_name":"Edit","tool_input":{"file_path":"E:\\p\\src\\main\\java\\A.java"}}'
hook "src/main/resources is blocked"               2 '{"tool_name":"Write","tool_input":{"file_path":"/r/src/main/resources/app.yml"}}'
hook "MultiEdit with one src/main target blocked"  2 '{"tool_name":"MultiEdit","tool_input":{"edits":[{"file_path":"src/test/A.java"},{"file_path":"src/main/A.java"}]}}'
hook "GAP-1 Bash sed -i to src/main is blocked"    2 '{"tool_name":"Bash","tool_input":{"command":"sed -i s/1/2/ src/main/java/demo/A.java"}}'
hook "GAP-1 Bash redirect to src/main is blocked"  2 '{"tool_name":"Bash","tool_input":{"command":"cat > src/main/java/demo/A.java"}}'
hook "GAP-1 Bash tee to src/main is blocked"       2 '{"tool_name":"Bash","tool_input":{"command":"echo x | tee src/main/A.java"}}'
hook "GAP-1 Bash cp into src/main is blocked"      2 '{"tool_name":"Bash","tool_input":{"command":"cp /tmp/A.java src/main/A.java"}}'
hook "GAP-1 Bash git checkout src/main is blocked" 2 '{"tool_name":"Bash","tool_input":{"command":"git checkout x -- src/main/A.java"}}'
hook "GAP-4 self-approval tag is blocked"          2 '{"tool_name":"Bash","tool_input":{"command":"git tag plan-approved-deadbeef1234"}}'
hook "GAP-4 writing baseline.json is blocked"      2 '{"tool_name":"Write","tool_input":{"file_path":".testing/baseline.json"}}'
hook "unparseable payload fails closed"            2 'not json'

echo "== hook: must stay allowed =="
hook "Write to src/test"                           0 '{"tool_name":"Write","tool_input":{"file_path":"src/test/java/demo/ATest.java"}}'
hook "Write plan.md (content is phase 2's job)"    0 '{"tool_name":"Write","tool_input":{"file_path":".testing/plan.md"}}'
hook "reading src/main with grep"                  0 '{"tool_name":"Bash","tool_input":{"command":"grep -rn foo src/main/java"}}'
hook "cat src/main"                                0 '{"tool_name":"Bash","tool_input":{"command":"cat src/main/java/demo/A.java"}}'
hook "sed -i on src/test"                          0 '{"tool_name":"Bash","tool_input":{"command":"sed -i s/a/b/ src/test/A.java"}}'
hook "mvn verify"                                  0 '{"tool_name":"Bash","tool_input":{"command":"mvn -q verify"}}'
hook "src/mainline is not a false positive"        0 '{"tool_name":"Write","tool_input":{"file_path":"src/mainline/Foo.java"}}'
hook "an ordinary release tag"                     0 '{"tool_name":"Bash","tool_input":{"command":"git tag v1.2.3"}}'

# ------------------------------------------------------------ PIT report cases
echo "== PIT report parsing =="
pit_dir=$(mktemp -d); mkdir -p "$pit_dir/r/run1"
w() { printf '%s' "$1" > "$pit_dir/r/run1/mutations.xml"; }
m() { echo "<mutation status=\"$1\"><mutatedClass>demo.A</mutatedClass></mutation>"; }

w "<mutations>$(m KILLED)$(m SURVIVED)</mutations>"
got=$("$PY" "$PITS" --reports-dir "$pit_dir/r" 2>/dev/null)
check "GAP-6 double-quoted one-line XML scores 50.0" "50.0" "$got"

w "<mutations>
$(printf "<mutation status='KILLED'><mutatedClass>demo.A</mutatedClass></mutation>")
$(printf "<mutation status='SURVIVED'><mutatedClass>demo.A</mutatedClass></mutation>")
</mutations>"
got=$("$PY" "$PITS" --reports-dir "$pit_dir/r" 2>/dev/null)
check "single-quoted multi-line XML scores 50.0" "50.0" "$got"

w "<mutations>$(m KILLED)$(m TIMED_OUT)</mutations>"
got=$("$PY" "$PITS" --reports-dir "$pit_dir/r" 2>/dev/null)
check "TIMED_OUT counts as detected" "100.0" "$got"

w "<mutations>$(m KILLED)</mutations>"
"$PY" "$PITS" --reports-dir "$pit_dir/r" --min-mtime "$("$PY" -c 'import time;print(time.time()+60)')" >/dev/null 2>&1
check "GAP-5 a report older than the run is refused" 4 "$?"

printf 'demo.A\ndemo.B\n' > "$pit_dir/scope.txt"
"$PY" "$PITS" --reports-dir "$pit_dir/r" --expect-scope-file "$pit_dir/scope.txt" >/dev/null 2>&1
check "GAP-6b a score from a different class scope is refused" 5 "$?"

"$PY" "$PITS" --reports-dir "$pit_dir/none" >/dev/null 2>&1
check "a missing report is an error, not a pass" 3 "$?"
rm -rf "$pit_dir"

# --------------------------------------------------------------- approval cases
echo "== approval gate =="
ap=$(mktemp -d)
( cd "$ap" && git init -q && git config user.email t@e.com && git config user.name t
  mkdir -p .testing && printf 'Status: PROPOSED\n# Plan\n' > .testing/plan.md
  git add -A && git commit -qm plan ) >/dev/null 2>&1
( cd "$ap" && "$PY" "$APPROVAL" --verify ) >/dev/null 2>&1
check "an unapproved plan is not approved" 1 "$?"
( cd "$ap" && git tag "$("$PY" "$APPROVAL" --name)" && "$PY" "$APPROVAL" --verify ) >/dev/null 2>&1
check "a plan tagged by a person is approved" 0 "$?"
( cd "$ap" && sed -i 's/PROPOSED/APPROVED/' .testing/plan.md && "$PY" "$APPROVAL" --verify ) >/dev/null 2>&1
check "GAP-2 editing the plan to APPROVED does not approve it" 1 "$?"
rm -rf "$ap"

# ------------------------------------------------------------------ guard cases
echo "== guard on a repo =="
guard_case() { # name expected_exit change_cmd
  local name=$1 expected=$2 change=$3 dir
  dir=$(mktemp -d)
  ( cd "$dir" || exit 1
    git init -q && git config user.email t@e.com && git config user.name t
    mkdir -p src/main/java/demo src/test/java/demo
    printf 'class A { int v() { return 1; } }\n' > src/main/java/demo/A.java
    cat > src/test/java/demo/ATest.java <<'EOF'
class ATest {
  @Test
  void t1() { assertEquals(1, new A().v()); }
  @Test
  void t2() { assertTrue(new A().v() > 0); }
}
EOF
    git add -A && git commit -qm base
    eval "$change"
    git add -A && git commit -qm change 2>/dev/null || true
    GUARD_SKIP_BUILD=1 BASE_REF=HEAD~1 bash "$GUARD" > out.txt 2>&1
    echo $? > exit.txt ) >/dev/null 2>&1
  check "$name" "$expected" "$(cat "$dir/exit.txt")"
  rm -rf "$dir"
}

guard_case "a clean test-only addition passes" 0 \
  "printf 'class ATest {\n  @Test\n  void t1() { assertEquals(1, new A().v()); }\n  @Test\n  void t2() { assertTrue(new A().v() > 0); }\n  @Test\n  void t3() { assertEquals(1, new A().v()); }\n}\n' > src/test/java/demo/ATest.java"
guard_case "a change under src/main fails" 1 \
  "printf 'class A { int v() { return 2; } }\n' > src/main/java/demo/A.java"
guard_case "a new Thread.sleep fails" 1 \
  "printf 'class ATest { @Test void t() throws Exception { Thread.sleep(1); assertTrue(true); } }\n' > src/test/java/demo/ATest.java"
guard_case "a new @Ignore fails" 1 \
  "printf 'class ATest { @Ignore @Test void t() { assertTrue(true); } }\n' > src/test/java/demo/ATest.java"
guard_case "GAP-3a deleting a test fails" 1 \
  "printf 'class ATest {\n  @Test\n  void t1() { assertEquals(1, new A().v()); }\n}\n' > src/test/java/demo/ATest.java"
guard_case "GAP-3b removing assertions fails" 1 \
  "printf 'class ATest {\n  @Test\n  void t1() { new A().v(); }\n  @Test\n  void t2() { new A().v(); }\n}\n' > src/test/java/demo/ATest.java"

# GAP-3c: found by attacking the fixed harness. Comparing only against the branch
# base let a mid-branch deletion through, because the total was still above the
# base. The guard now also compares against the previous commit.
mid_branch_case() { # name expected_exit
  local dir; dir=$(mktemp -d)
  ( cd "$dir" || exit 1
    git init -q && git config user.email t@e.com && git config user.name t
    mkdir -p src/main/java/demo src/test/java/demo
    printf 'class A { int v() { return 1; } }\n' > src/main/java/demo/A.java
    printf 'class ATest {\n  @Test\n  void t1() { assertEquals(1, new A().v()); }\n}\n' > src/test/java/demo/ATest.java
    git add -A && git commit -qm base && git tag basetag
    # item 1 adds plenty of tests
    printf 'class ATest {\n  @Test\n  void t1() { assertEquals(1, new A().v()); }\n  @Test\n  void t2() { assertEquals(1, new A().v()); }\n  @Test\n  void t3() { assertEquals(1, new A().v()); }\n  @Test\n  void t4() { assertEquals(1, new A().v()); }\n}\n' > src/test/java/demo/ATest.java
    git add -A && git commit -qm "test: ITEM-01 add cases"
    # item 2 silently drops one: still above basetag, so a base-only ratchet passes
    printf 'class ATest {\n  @Test\n  void t1() { assertEquals(1, new A().v()); }\n  @Test\n  void t2() { assertEquals(1, new A().v()); }\n  @Test\n  void t3() { assertEquals(1, new A().v()); }\n}\n' > src/test/java/demo/ATest.java
    git add -A && git commit -qm "test: ITEM-02"
    GUARD_SKIP_BUILD=1 BASE_REF=basetag bash "$GUARD" > out.txt 2>&1
    echo $? > exit.txt ) >/dev/null 2>&1
  check "$1" "$2" "$(cat "$dir/exit.txt")"
  rm -rf "$dir"
}
mid_branch_case "GAP-3c a mid-branch deletion still above the base fails" 1

# GAP-5b: freshness is anchored to the last commit touching src/, not to HEAD.
# Anchored to HEAD, a docs-only commit made PIT look stale, which would train
# people to ignore the check. A src change or an old report must still be stale.
fresh_case() { # name expected_exit backdate second_commit_target
  local dir; dir=$(mktemp -d)
  ( cd "$dir" || exit 1
    git init -q && git config user.email t@e.com && git config user.name t
    mkdir -p src/main/java/demo src/test/java/demo target/pit-reports/r .testing
    printf 'class A { int v() { return 1; } }\n' > src/main/java/demo/A.java
    printf 'class ATest { @Test void t() { assertEquals(1, new A().v()); } }\n' > src/test/java/demo/ATest.java
    git add -A && git commit -qm base && git tag b
    printf '<mutations><mutation status="KILLED"><mutatedClass>demo.A</mutatedClass></mutation></mutations>' \
      > target/pit-reports/r/mutations.xml
    echo '{"mutation_score": 50.0}' > .testing/baseline.json
    [ "$3" = "backdate" ] && touch -d '2020-01-01' target/pit-reports/r/mutations.xml
    sleep 1
    if [ "$4" = "src" ]; then
      printf 'class ATest { @Test void t() { assertEquals(1, new A().v()); } @Test void t2() { assertTrue(true); } }\n' \
        > src/test/java/demo/ATest.java
    else
      echo notes > NOTES.md
    fi
    git add -A && git commit -qm second
    BUILD_CMD=true BASE_REF=b bash "$GUARD" > out.txt 2>&1
    echo $? > exit.txt ) >/dev/null 2>&1
  check "$1" "$2" "$(cat "$dir/exit.txt")"
  rm -rf "$dir"
}
fresh_case "GAP-5b a docs-only commit does not make PIT look stale" 0 keep docs
fresh_case "a src commit after the report is stale"                1 keep src
fresh_case "a backdated report is stale even with no src change"   1 backdate docs

# ------------------------------------------------------------ pom setup cases
echo "== pom setup =="
SETUP="$HARNESS/scripts/setup_pom.py"
pom_dir=$(mktemp -d)
write_pom() { cat > "$pom_dir/pom.xml"; }

write_pom <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.acme</groupId><artifactId>svc</artifactId><version>1.0</version>
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId><scope>test</scope></dependency>
  </dependencies>
  <build><plugins>
    <plugin><groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-maven-plugin</artifactId></plugin>
  </plugins></build>
</project>
XML
"$PY" "$SETUP" --check "$pom_dir/pom.xml" >/dev/null 2>&1
check "a pom without PIT fails --check" 1 "$?"
"$PY" "$SETUP" "$pom_dir/pom.xml" >/dev/null 2>&1
check "patching a Spring Boot pom succeeds" 0 "$?"
"$PY" "$SETUP" --check "$pom_dir/pom.xml" >/dev/null 2>&1
check "the patched pom passes --check" 0 "$?"
grep -q "pitest-junit5-plugin" "$pom_dir/pom.xml"
check "JUnit 5 project gets the pitest-junit5-plugin" 0 "$?"
grep -q "<outputFormat>XML</outputFormat>" "$pom_dir/pom.xml"
check "XML output format is present" 0 "$?"
"$PY" -c "import xml.etree.ElementTree as ET,sys;ET.parse(sys.argv[1])" "$pom_dir/pom.xml" >/dev/null 2>&1
check "the patched pom is valid XML" 0 "$?"
before=$(md5sum "$pom_dir/pom.xml" | cut -d" " -f1)
"$PY" "$SETUP" "$pom_dir/pom.xml" >/dev/null 2>&1
after=$(md5sum "$pom_dir/pom.xml" | cut -d" " -f1)
check "re-running changes nothing (idempotent)" "$before" "$after"

# JUnit 4 must NOT get the junit5 plugin
write_pom <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.acme</groupId><artifactId>old</artifactId><version>1.0</version>
  <dependencies><dependency><groupId>junit</groupId><artifactId>junit</artifactId>
    <version>4.13.2</version><scope>test</scope></dependency></dependencies>
</project>
XML
"$PY" "$SETUP" "$pom_dir/pom.xml" >/dev/null 2>&1
grep -q "pitest-junit5-plugin" "$pom_dir/pom.xml"
check "JUnit 4 project does not get the junit5 plugin" 1 "$?"
grep -q "<build>" "$pom_dir/pom.xml"
check "a pom with no <build> gets one" 0 "$?"

# existing PIT without XML keeps its own config
write_pom <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.acme</groupId><artifactId>svc</artifactId><version>1.0</version>
  <build><plugins><plugin>
    <groupId>org.pitest</groupId><artifactId>pitest-maven</artifactId><version>1.19.0</version>
    <configuration><targetClasses><param>com.acme.*</param></targetClasses></configuration>
  </plugin></plugins></build>
</project>
XML
"$PY" "$SETUP" --no-jacoco "$pom_dir/pom.xml" >/dev/null 2>&1
grep -q "com.acme.\*" "$pom_dir/pom.xml"
check "existing pitest config is preserved" 0 "$?"
grep -q "1.19.0" "$pom_dir/pom.xml"
check "existing pitest version is not bumped" 0 "$?"
grep -q "<outputFormat>XML</outputFormat>" "$pom_dir/pom.xml"
check "XML is added to an existing pitest plugin" 0 "$?"

# aggregator pom is refused
write_pom <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.acme</groupId><artifactId>parent</artifactId><version>1.0</version>
  <packaging>pom</packaging><modules><module>a</module></modules>
</project>
XML
"$PY" "$SETUP" "$pom_dir/pom.xml" >/dev/null 2>&1
check "an aggregator pom is refused without --force" 2 "$?"
"$PY" "$SETUP" --force "$pom_dir/pom.xml" >/dev/null 2>&1
check "--force patches an aggregator pom" 0 "$?"

printf '<project><unclosed>\n' > "$pom_dir/pom.xml"
"$PY" "$SETUP" "$pom_dir/pom.xml" >/dev/null 2>&1
check "malformed XML is refused, not overwritten" 1 "$?"
"$PY" "$SETUP" "$pom_dir/missing.xml" >/dev/null 2>&1
check "a missing pom is a clear error" 2 "$?"
rm -rf "$pom_dir"

echo
echo "Passed: $pass   Failed: $fail"
echo "Not covered here: mvn verify, a real PIT run, and CI's baseline recomputation."
echo "Those need Maven and a CI runner; scripts/ci-check.sh is the authoritative check."
[ "$fail" -eq 0 ]
