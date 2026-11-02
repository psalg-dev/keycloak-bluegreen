package demo.kc;

import org.keycloak.models.UserSessionModel;

/** User session note `login_ctx` (set by LoginContextAuthenticator) -> claim `login_ctx`. */
public class LoginContextMapper extends ClaimMapper {
    public LoginContextMapper() {
        super(LoginContextAuthenticator.NOTE);
    }

    @Override
    String value(UserSessionModel us) {
        return us.getNote(LoginContextAuthenticator.NOTE);
    }

    @Override
    public String getId() {
        return "demo-login-context-mapper";
    }

    @Override
    public String getDisplayType() {
        return "Demo login context";
    }

    @Override
    public String getHelpText() {
        return "User session note 'login_ctx' -> claim 'login_ctx' (access, id, userinfo).";
    }
}
