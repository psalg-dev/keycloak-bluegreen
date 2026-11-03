// Orchestration only: every bit of logic lives in scripts/. One stage per demo phase (scripts/demo.sh <case> <phase>),
// so the stage view shows where a run is and where it failed. Params come from jenkins/jobs.groovy (no parameters {}
// block here, it would override them) and arrive as env vars.
def phase(String p) {
  sh """#!/usr/bin/env bash
set -euo pipefail
export RUN_MAINTENANCE
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
    failure {
      // a failed stage must not leave k6 hammering the cluster; collect what it has for the post-mortem
      sh '''#!/usr/bin/env bash
scripts/load.sh stop || true # stderr stays: log() writes there (build #10 lost its k6 lines silently)
'''
    }
    always {
      archiveArtifacts artifacts: 'out/**', allowEmptyArchive: true
    }
  }
}
