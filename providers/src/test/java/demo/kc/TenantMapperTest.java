package demo.kc;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import org.junit.jupiter.api.Test;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;

class TenantMapperTest {
    final TenantMapper mapper = new TenantMapper();
    // empty config on purpose: no access.token.claim toggles needed
    final ProtocolMapperModel model = new ProtocolMapperModel();
    final KeycloakSession session = mock(KeycloakSession.class);

    UserSessionModel userSession(String tenant) {
        UserModel user = mock(UserModel.class);
        when(user.getFirstAttribute("tenant")).thenReturn(tenant);
        UserSessionModel us = mock(UserSessionModel.class);
        when(us.getUser()).thenReturn(user);
        return us;
    }

    @Test
    void tenantAttributeBecomesClaimInAccessIdAndUserinfo() {
        UserSessionModel us = userSession("acme");
        AccessToken at = mapper.transformAccessToken(new AccessToken(), model, session, us, null);
        IDToken id = mapper.transformIDToken(new IDToken(), model, session, us, null);
        AccessToken ui = mapper.transformUserInfoToken(new AccessToken(), model, session, us, null);
        assertEquals("acme", at.getOtherClaims().get("tenant"));
        assertEquals("acme", id.getOtherClaims().get("tenant"));
        assertEquals("acme", ui.getOtherClaims().get("tenant"));
    }

    @Test
    void noAttributeNoClaim() {
        AccessToken at = mapper.transformAccessToken(new AccessToken(), model, session, userSession(null), null);
        assertFalse(at.getOtherClaims().containsKey("tenant"));
    }
}
