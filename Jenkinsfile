// Orchestration only: every bit of logic lives in scripts/. Params come from jenkins/jobs.groovy
// (no parameters {} block here, it would override them) and arrive as env vars.
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
    stage('Demo') {
      steps {
        sh '''#!/usr/bin/env bash
set -euo pipefail
export RUN_MAINTENANCE
scripts/demo.sh "$CASE"
'''
      }
    }
  }
  post {
    always {
      archiveArtifacts artifacts: 'out/**', allowEmptyArchive: true
    }
  }
}
