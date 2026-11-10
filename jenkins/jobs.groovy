// The branch every job builds: the one /repo has checked out when Jenkins (re)loads this file (container start or a
// CasC reload), so a clone of a feature branch builds that branch, not main. /repo is the bind-mounted checkout.
// After `git switch` on the host: `docker compose restart jenkins`. KC_BRANCH (env of the Jenkins container) overrides.
def repoBranch = System.getenv('KC_BRANCH') ?: {
  def head = new File('/repo/.git/HEAD')
  def m = head.exists() ? (head.text =~ /ref: refs\/heads\/(\S+)/) : null
  m ? m[0][1] : 'main' // detached HEAD or a worktree (.git is a file): main
}()

pipelineJob('kc-bluegreen') {
  description('Blue-green Keycloak upgrade demo: one case per build. Runs scripts/demo.sh.')
  parameters {
    choiceParam('CASE', ['patch', 'minor', 'major', 'patch-rollback', 'minor-rollback'], 'Upgrade case (FROM/TO versions come from cases.env); *-rollback = switch, soak, roll back. One build per case: the report (post step) collects every case the workspace holds.')
    booleanParam('RUN_MAINTENANCE', false, 'Also run the config-cli maintenance stage (breaking changes, behind a freeze). Exported as true|false.')
    choiceParam('PROFILE', ['default', 'laptop'], 'Must match the profile the cluster was created with (PROFILE=laptop docker compose up launcher); a mismatch fails the Reset stage before it deletes anything. laptop = 2 Keycloak pods/color, 2 zones, gvenzl Free Oracle image (scripts/lib/kc.sh).')
  }
  definition {
    cpsScm {
      scm {
        git {
          remote { url('file:///repo') }
          branch("*/${repoBranch}")
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
          branch("*/${repoBranch}")
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
          branch("*/${repoBranch}")
        }
      }
      scriptPath('jenkins/security.Jenkinsfile')
    }
  }
}
