// Orchestration only: every bit of logic lives in scripts/. One stage per demo phase (scripts/demo.sh <case> <phase>),
// so the stage view shows where a run is and where it failed. Params come from jenkins/jobs.groovy (no parameters {}
// block here, it would override them) and arrive as env vars.
def phase(String p) {
  sh """#!/usr/bin/env bash
set -euo pipefail
export RUN_MAINTENANCE PROFILE DB_ENGINE
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
    stage('Reset') {
      steps {
        script {
          phase('reset')
          // sentinels of the parallel Load/Cutover branches (a previous failed build can leave them behind)
          sh 'rm -f out/.warm-done out/.cutover-done out/.cutover-failed'
        }
      }
    }
    stage('Install') { steps { script { phase('install') } } }
    // The load is its own branch for the whole run: it starts k6, warms up, waits for the cutover to finish and then
    // cools down and collects. Pipeline steps never wait on the load; the only ordering point is the warm-up (the
    // switch starts once out/.warm-done exists, so sessions exist before the flip).
    stage('Load || Cutover') {
      parallel {
        stage('Load') {
          steps {
            script {
              phase('warmup')
              sh 'mkdir -p out && touch out/.warm-done'
              sh '''#!/usr/bin/env bash
set -euo pipefail
for _ in $(seq 900); do
  [[ -f out/.cutover-done || -f out/.cutover-failed ]] && break
  sleep 2
done
[[ -f out/.cutover-done ]]
'''
              phase('cooldown')
            }
          }
        }
        stage('Cutover') {
          steps {
            script {
              sh '''#!/usr/bin/env bash
set -euo pipefail
for _ in $(seq 300); do [[ -f out/.warm-done ]] && break; sleep 2; done
[[ -f out/.warm-done ]]
'''
              try {
                phase('switch')
                if (env.CASE.endsWith('-rollback')) { phase('rollback') }
              } catch (e) {
                sh 'mkdir -p out && touch out/.cutover-failed || true'
                throw e
              }
              sh 'touch out/.cutover-done'
            }
          }
        }
      }
    }
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
for k in out/*/k6.jsonl out/*/*/k6.jsonl; do
  [[ -f $k && $(stat -c %Y "$k") -ge $start ]] || continue
  jq -n --arg build "$BUILD_NUMBER" --arg commit "${GIT_COMMIT:-}" --arg url "${BUILD_URL:-}" \\
    '{build: $build, commit: $commit, url: $url}' > "${k%/k6.jsonl}/meta.json"
done
scripts/report.sh
# one report per engine: DB_ENGINE=oracle cases live in out/oracle/<case>/
if compgen -G 'out/oracle/*/k6.jsonl' >/dev/null; then scripts/report.sh out/oracle; fi
''')
          if (rc != 0) { unstable("scripts/report.sh failed (exit ${rc})") }
        }
      }
      archiveArtifacts artifacts: 'out/**', allowEmptyArchive: true
    }
  }
}
