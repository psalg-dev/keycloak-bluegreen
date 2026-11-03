// Orchestration only: every bit of logic lives in scripts/. One stage per demo phase (scripts/demo.sh <case> <phase>),
// so the stage view shows where a run is and where it failed. Params come from jenkins/jobs.groovy (no parameters {}
// block here, it would override them) and arrive as env vars.
def phase(String p) {
  sh """#!/usr/bin/env bash
set -euo pipefail
export RUN_MAINTENANCE PROFILE
scripts/demo.sh "\$CASE" ${p}
"""
}

pipeline {
  agent any
  options {
    timestamps()
    timeout(time: 60, unit: 'MINUTES')
    disableConcurrentBuilds()
  }
  stages {
    stage('Connect') {
      steps {
        sh '''#!/usr/bin/env bash
set -euo pipefail
. scripts/lib/kc.sh
kube_connect
'''
      }
    }
    stage('Reset') { steps { script { phase('reset') } } }
    stage('Install') { steps { script { phase('install') } } }
    stage('Load + warm-up') { steps { script { phase('warmup') } } }
    stage('Switch') { steps { script { phase('switch') } } }
    stage('Soak + rollback') {
      when { expression { env.CASE.endsWith('-rollback') } }
      steps { script { phase('rollback') } }
    }
    stage('Cool-down') { steps { script { phase('cooldown') } } }
    stage('Gate') { steps { script { phase('gate') } } }
  }
  post {
    always {
      // A failed stage must not leave k6 hammering the cluster; collect its lines (out/k6.jsonl) for the post-mortem.
      // Here, not in post { failure }: declarative runs `always` first, so `failure` came after the archive (build #10).
      script {
        if (currentBuild.currentResult == 'FAILURE') {
          sh '''#!/usr/bin/env bash
. scripts/lib/kc.sh
# only while k6 still runs (a failed gate comes after cool-down already stopped it)
if kubectl -n load get job k6 >/dev/null 2>&1; then scripts/load.sh stop || true; fi
'''
        }
      }
      // Report: one HTML page over EVERY out/<case>/ in the workspace, i.e. this build's case plus the cases earlier
      // builds left there (the workspace keeps out/; docs/failure-modes.md says how to reset it). In post, not a stage, so it
      // also runs when a stage or the gate failed. A report failure marks the build UNSTABLE, never hides the result.
      script {
        withEnv(["BUILD_START_MS=${currentBuild.startTimeInMillis}"]) {
          int rc = sh(returnStatus: true, script: '''#!/usr/bin/env bash
set -euo pipefail
start=$((BUILD_START_MS / 1000))
# build/commit for the case dirs THIS build wrote (k6.jsonl newer than the build start); older dirs keep theirs
for k in out/*/k6.jsonl; do
  [[ -f $k && $(stat -c %Y "$k") -ge $start ]] || continue
  jq -n --arg build "$BUILD_NUMBER" --arg commit "${GIT_COMMIT:-}" --arg url "${BUILD_URL:-}" \\
    '{build: $build, commit: $commit, url: $url}' > "${k%/k6.jsonl}/meta.json"
done
scripts/report.sh
''')
          if (rc != 0) { unstable("scripts/report.sh failed (exit ${rc})") }
        }
      }
      archiveArtifacts artifacts: 'out/**', allowEmptyArchive: true
    }
  }
}
