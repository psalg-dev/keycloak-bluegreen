// Orchestration only: scripts/security/kcwarden.sh does the work. Job (params, nightly cron): jenkins/jobs.groovy.
pipeline {
  agent any
  options {
    timestamps()
    timeout(time: 15, unit: 'MINUTES')
    disableConcurrentBuilds() // kcwarden.sh binds 127.0.0.1:443 for its port-forward
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
    stage('kcwarden') {
      steps {
        sh '''#!/usr/bin/env bash
set -euo pipefail
scripts/security/kcwarden.sh
'''
      }
    }
  }
  post {
    always {
      archiveArtifacts artifacts: 'out/security/**', allowEmptyArchive: true
    }
  }
}
