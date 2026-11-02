// Orchestration only: scripts/security/run.sh does the work. Job (param PROBES, nightly cron): jenkins/jobs.groovy.
pipeline {
  agent any
  options {
    timestamps()
    timeout(time: 30, unit: 'MINUTES')
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
    stage('Probes') {
      steps {
        sh '''#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2086 # PROBES is a space-separated list; blank = all
scripts/security/run.sh ${PROBES:-}
'''
      }
    }
  }
  post {
    always {
      junit testResults: 'out/security/junit.xml', allowEmptyResults: true
      archiveArtifacts artifacts: 'out/security/**', allowEmptyArchive: true
    }
  }
}
