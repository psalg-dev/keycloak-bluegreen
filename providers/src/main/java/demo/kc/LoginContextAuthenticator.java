package demo.kc;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.Properties;

import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.authentication.Authenticator;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

/**
 * No-UI step for the IdP post-broker-login flow: user session note login_ctx=v<PROVIDER_VERSION>.
 * Auth-session user-session notes are copied into the user session when it is created (survives refresh).
 */
public class LoginContextAuthenticator implements Authenticator {
    static final String NOTE = "login_ctx";
    static final String VERSION = "v" + load().getProperty("provider.version");

    private static Properties load() {
        try (InputStream in = LoginContextAuthenticator.class.getResourceAsStream("version.properties")) {
            Properties p = new Properties();
            p.load(in);
            return p;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @Override
    public void authenticate(AuthenticationFlowContext context) {
        context.getAuthenticationSession().setUserSessionNote(NOTE, VERSION);
        context.success();
    }

    @Override
    public void action(AuthenticationFlowContext context) {
    }

    @Override
    public boolean requiresUser() {
        return false;
    }

    @Override
    public boolean configuredFor(KeycloakSession session, RealmModel realm, UserModel user) {
        return true;
    }

    @Override
    public void setRequiredActions(KeycloakSession session, RealmModel realm, UserModel user) {
    }

    @Override
    public void close() {
    }
}
