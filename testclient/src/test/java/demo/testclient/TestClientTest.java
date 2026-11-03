package demo.testclient;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.mock.web.MockHttpSession;
import org.springframework.security.core.authority.AuthorityUtils;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClient;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.core.OAuth2AccessToken;
import org.springframework.security.oauth2.core.OAuth2RefreshToken;
import org.springframework.security.oauth2.core.oidc.OidcIdToken;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.context.WebApplicationContext;

/**
 * Behaviour of the relying party against a stub Keycloak (JDK HttpServer: token endpoint + JWKS). The stub is the
 * system boundary; everything inside the app (Spring Security, client manager, filters) is real.
 */
@SpringBootTest(properties = {"TESTCLIENT_BC_SECRET=bc-test", "TESTCLIENT_FC_SECRET=fc-test",
        "spring.ssl.bundle.pem.demo-ca.truststore.certificate=classpath:test-ca.crt"})
@ExtendWith(OutputCaptureExtension.class)
class TestClientTest {

    static final RSAKey KEY = rsa();
    static final HttpServer KEYCLOAK = stubKeycloak();
    static volatile String tokenRequest;

    @DynamicPropertySource
    static void keycloak(DynamicPropertyRegistry r) {
        r.add("demo.issuer", () -> "http://127.0.0.1:" + KEYCLOAK.getAddress().getPort() + "/{net}");
    }

    @Autowired
    WebApplicationContext ctx;
    @Autowired
    TestClientApplication.Sessions sessions;
    @Autowired
    ClientRegistrationRepository registrations;
    @Autowired
    OAuth2AuthorizedClientRepository authorizedClients;

    MockMvc mvc;

    @BeforeEach
    void mvc() {
        mvc = MockMvcBuilders.webAppContextSetup(ctx).apply(SecurityMockMvcConfigurers.springSecurity()).build();
    }

    @Test
    void meWithoutLoginIs401() throws Exception {
        mvc.perform(get("/me")).andExpect(status().isUnauthorized());
        mvc.perform(get("/call/jwt")).andExpect(status().isUnauthorized());
    }

    @Test
    void loginSendsIdpHintAndPkce() throws Exception {
        mvc.perform(get("/login/bc-net2")).andExpect(status().isFound())
                .andExpect(header().string("Location", "/oauth2/authorization/bc-net2"));
        String authorize = mvc.perform(get("/oauth2/authorization/bc-net2")).andExpect(status().isFound())
                .andReturn().getResponse().getHeader("Location");
        assertThat(authorize).startsWith(issuer("net2") + "/protocol/openid-connect/auth?")
                .contains("client_id=testclient-bc", "kc_idp_hint=legacy-net2", "code_challenge_method=S256",
                        "redirect_uri=http://localhost/login/oauth2/code/bc-net2");
        mvc.perform(get("/login/nope")).andExpect(status().isNotFound());
    }

    @Test
    void frontChannelLogoutEndsTheSessionWithThatSid(CapturedOutput out) throws Exception {
        MockHttpSession session = new MockHttpSession();
        MockHttpServletRequest login = new MockHttpServletRequest();
        login.setSession(session);
        sessions.loggedIn(login, oidc("fc-net1", "sid-fc-1"));

        mvc.perform(get("/frontchannel-logout").param("iss", issuer("net1")).param("sid", "sid-fc-1"))
                .andExpect(status().isOk());
        assertThat(session.isInvalid()).isTrue();
        assertThat(out).contains("\"event\":\"frontchannel_logout\",\"sid\":\"sid-fc-1\",\"iss\":\"" + issuer("net1")
                + "\",\"found_session\":true}");

        mvc.perform(get("/frontchannel-logout").param("sid", "unknown-sid")).andExpect(status().isOk());
        assertThat(out).contains("\"sid\":\"unknown-sid\",\"iss\":null,\"found_session\":false}");
    }

    @Test
    void refreshInvalidGrantFailsTheCall(CapturedOutput out) throws Exception {
        OAuth2AuthenticationToken auth = oidc("bc-net1", "sid-bc-1");
        MockHttpSession session = new MockHttpSession();
        MockHttpServletRequest req = new MockHttpServletRequest();
        req.setSession(session);
        Instant expired = Instant.now().minusSeconds(120);
        authorizedClients.saveAuthorizedClient(new OAuth2AuthorizedClient(registrations.findByRegistrationId("bc-net1"),
                "user0042", new OAuth2AccessToken(OAuth2AccessToken.TokenType.BEARER, "at-1", expired.minusSeconds(60), expired),
                new OAuth2RefreshToken("rt-1", expired.minusSeconds(60))), auth, req, new MockHttpServletResponse());

        String body = mvc.perform(get("/call/jwt").session(session).with(authentication(auth)))
                .andExpect(status().isUnauthorized()).andReturn().getResponse().getContentAsString();

        assertThat(body).isEqualTo("{\"status\":401,\"upstream_status\":null,\"refreshed\":false,\"error\":\"invalid_grant\"}");
        assertThat(tokenRequest).contains("grant_type=refresh_token", "refresh_token=rt-1");
        assertThat(out).contains("\"event\":\"refresh\",\"registration\":\"bc-net1\",\"sid\":\"sid-bc-1\",\"ok\":false,\"error\":\"invalid_grant\"")
                .contains("\"event\":\"call\",\"target\":\"jwt\",\"status\":401,\"upstream_status\":null,\"refreshed\":false");

        // the failed client was dropped from the session: no silent re-authentication, the next call says so
        assertThat(mvc.perform(get("/call/introspect").session(session).with(authentication(auth)))
                .andExpect(status().isUnauthorized()).andReturn().getResponse().getContentAsString())
                .contains("\"error\":\"client_authorization_required\"");
    }

    @Test
    void backChannelAliasPicksTheRegistrationByIssuer(CapturedOutput out) throws Exception {
        mvc.perform(post("/logout/connect/back-channel/bc").param("logout_token", logoutToken(issuer("net2"), KEY)))
                .andExpect(status().isOk());
        assertThat(out).contains("\"event\":\"backchannel_logout\",\"registration\":\"bc-net2\",\"sid\":\"sid-bc-2\","
                + "\"sub\":\"user0042\",\"iss\":\"" + issuer("net2") + "\",\"ok\":true,\"error\":null");

        RSAKey forged = new RSAKeyGenerator(2048).keyID(KEY.getKeyID()).generate();
        mvc.perform(post("/logout/connect/back-channel/bc").param("logout_token", logoutToken(issuer("net1"), forged)))
                .andExpect(status().isBadRequest());
        assertThat(out).contains("\"registration\":\"bc-net1\",\"sid\":\"sid-bc-2\",\"sub\":\"user0042\",\"iss\":\""
                + issuer("net1") + "\",\"ok\":false,\"error\":\"");
    }

    static String issuer(String net) {
        return "http://127.0.0.1:" + KEYCLOAK.getAddress().getPort() + "/" + net;
    }

    static OAuth2AuthenticationToken oidc(String registration, String sid) {
        String net = registration.substring(3);
        OidcIdToken id = OidcIdToken.withTokenValue("id-token").subject("user0042").issuer(issuer(net)).claim("sid", sid)
                .issuedAt(Instant.now()).expiresAt(Instant.now().plusSeconds(300)).build();
        return new OAuth2AuthenticationToken(new DefaultOidcUser(AuthorityUtils.createAuthorityList("OIDC_USER"), id),
                List.of(), registration);
    }

    static String logoutToken(String iss, RSAKey key) throws Exception {
        SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID())
                .type(new JOSEObjectType("logout+jwt")).build(),
                new JWTClaimsSet.Builder().issuer(iss).audience("testclient-bc").subject("user0042").claim("sid", "sid-bc-2")
                        .issueTime(new Date()).jwtID(UUID.randomUUID().toString())
                        .claim("events", Map.of("http://schemas.openid.net/event/backchannel-logout", Map.of())).build());
        jwt.sign(new RSASSASigner(key));
        return jwt.serialize();
    }

    static RSAKey rsa() {
        try {
            return new RSAKeyGenerator(2048).keyID("k1").generate();
        }
        catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    /** Token endpoint: always invalid_grant (Keycloak lost the session). JWKS: KEY. Same for every {net}. */
    static HttpServer stubKeycloak() {
        try {
            HttpServer s = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            s.createContext("/", ex -> {
                String path = ex.getRequestURI().getPath();
                if (path.endsWith("/protocol/openid-connect/token")) {
                    tokenRequest = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
                    reply(ex, 400, "{\"error\":\"invalid_grant\",\"error_description\":\"Session not active\"}");
                }
                else if (path.endsWith("/protocol/openid-connect/certs")) {
                    reply(ex, 200, new JWKSet(KEY.toPublicJWK()).toString());
                }
                else {
                    reply(ex, 404, "{}");
                }
            });
            s.start();
            return s;
        }
        catch (IOException e) {
            throw new IllegalStateException(e);
        }
    }

    static void reply(HttpExchange ex, int status, String json) throws IOException {
        byte[] b = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, b.length);
        ex.getResponseBody().write(b);
        ex.close();
    }
}
