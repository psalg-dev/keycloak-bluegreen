pipelineJob('kc-bluegreen') {
  description('Blue-green Keycloak upgrade demo: one case per build. Runs scripts/demo.sh.')
  parameters {
    choiceParam('CASE', ['patch', 'minor', 'major'], 'Upgrade case (FROM/TO versions come from cases.env)')
    booleanParam('RUN_MAINTENANCE', false, 'Also run the config-cli maintenance stage (breaking changes, behind a freeze). Exported as true|false.')
  }
  definition {
    cpsScm {
      scm {
        git {
          remote { url('file:///repo') }
          branch('*/main')
        }
      }
      scriptPath('Jenkinsfile')
    }
  }
}

// Proactive security scans, nightly. Logic in scripts/security/, probe list and expectations in security/README.md.
pipelineJob('kc-kcwarden') {
  description('kcwarden audit of realms master + demo. Runs scripts/security/kcwarden.sh.')
  properties {
    pipelineTriggers { triggers { cron { spec('H 2 * * *') } } }
  }
  definition {
    cpsScm {
      scm {
        git {
          remote { url('file:///repo') }
          branch('*/main')
        }
      }
      scriptPath('jenkins/kcwarden.Jenkinsfile')
    }
  }
}

pipelineJob('kc-security') {
  description('Security probes (regression gate). Runs scripts/security/run.sh; see security/README.md.')
  parameters {
    stringParam('PROBES', '', 'Space-separated probe names (e.g. "issuer netpol"); blank = all')
  }
  properties {
    pipelineTriggers { triggers { cron { spec('H 2 * * *') } } }
  }
  definition {
    cpsScm {
      scm {
        git {
          remote { url('file:///repo') }
          branch('*/main')
        }
      }
      scriptPath('jenkins/security.Jenkinsfile')
    }
  }
}
