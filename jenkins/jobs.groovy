pipelineJob('kc-bluegreen') {
  description('Blue-green Keycloak upgrade demo: one case per build. Runs scripts/demo.sh.')
  parameters {
    choiceParam('CASE', ['patch', 'minor', 'major', 'patch-rollback', 'minor-rollback'], 'Upgrade case (FROM/TO versions come from cases.env); *-rollback = switch, soak, roll back')
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
