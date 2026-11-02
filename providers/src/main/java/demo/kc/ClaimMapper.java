package demo.kc;

import java.util.List;

import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;

/** One string claim, always in access + id token + userinfo. Null value -> no claim. */
abstract class ClaimMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, OIDCIDTokenMapper, UserInfoTokenMapper {

    private final String claim;

    ClaimMapper(String claim) {
        this.claim = claim;
    }

    abstract String value(UserSessionModel userSession);

    // ponytail: the include-in-token toggles are ignored on purpose. Keycloak reads them as "true".equals(config),
    // so a mapper created without config would silently emit nothing. Add OIDCAttributeMapperHelper
    // .addIncludeInTokensConfig if a client ever needs to opt out.
    @Override
    public AccessToken transformAccessToken(AccessToken token, ProtocolMapperModel m, KeycloakSession s,
                                            UserSessionModel us, ClientSessionContext c) {
        setClaim(token, m, us, s, c);
        return token;
    }

    @Override
    public IDToken transformIDToken(IDToken token, ProtocolMapperModel m, KeycloakSession s,
                                    UserSessionModel us, ClientSessionContext c) {
        setClaim(token, m, us, s, c);
        return token;
    }

    @Override
    public AccessToken transformUserInfoToken(AccessToken token, ProtocolMapperModel m, KeycloakSession s,
                                              UserSessionModel us, ClientSessionContext c) {
        setClaim(token, m, us, s, c);
        return token;
    }

    @Override
    protected void setClaim(IDToken token, ProtocolMapperModel m, UserSessionModel us, KeycloakSession s,
                            ClientSessionContext c) {
        String v = us == null ? null : value(us);
        if (v != null) token.getOtherClaims().put(claim, v);
    }

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return List.of();
    }
}
