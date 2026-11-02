package demo.kc;

import static org.mockito.Mockito.*;

import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.sessions.AuthenticationSessionModel;

class LoginContextAuthenticatorTest {
    @Test
    void setsUserSessionNoteToProviderVersionAndSucceeds() {
        AuthenticationSessionModel authSession = mock(AuthenticationSessionModel.class);
        AuthenticationFlowContext ctx = mock(AuthenticationFlowContext.class);
        when(ctx.getAuthenticationSession()).thenReturn(authSession);

        new LoginContextAuthenticator().authenticate(ctx);

        // surefire passes the same -DPROVIDER_VERSION the jar was filtered with (image builds use 2)
        verify(authSession).setUserSessionNote("login_ctx", "v" + System.getProperty("PROVIDER_VERSION"));
        verify(ctx).success();
    }
}
