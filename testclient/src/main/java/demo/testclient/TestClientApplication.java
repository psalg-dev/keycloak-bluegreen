package demo.testclient;

import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import javax.net.ssl.SSLContext;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.ssl.SslBundles;
import org.springframework.context.annotation.Bean;
import org.springframework.context.event.EventListener;
import org.springframework.http.HttpStatus;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClient;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientProvider;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientProviderBuilder;
import org.springframework.security.oauth2.client.RefreshTokenOAuth2AuthorizedClientProvider;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.client.oidc.web.logout.OidcClientInitiatedLogoutSuccessHandler;
import org.springframework.security.oauth2.client.registration.ClientRegistration;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.registration.InMemoryClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizationRequestResolver;
import org.springframework.security.oauth2.client.web.DefaultOAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.web.HttpSessionOAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.core.AuthorizationGrantType;
import org.springframework.security.oauth2.core.OAuth2AuthorizationException;
import org.springframework.security.oauth2.core.endpoint.OAuth2ParameterNames;
import org.springframework.security.oauth2.core.oidc.IdTokenClaimNames;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.HttpStatusEntryPoint;
import org.springframework.security.web.authentication.SavedRequestAwareAuthenticationSuccessHandler;
import org.springframework.security.web.session.DisableEncodeUrlFilter;
import org.springframework.security.web.session.HttpSessionDestroyedEvent;
import org.springframework.security.web.session.HttpSessionEventPublisher;
import org.springframework.stereotype.Component;

/**
 * OIDC relying party for the cutover measurements (docs/test-apps-contract.md). Four registrations: {bc,fc} x {net1,net2}.
 * Endpoints are built from the issuer, not discovered: startup does not depend on Keycloak being reachable.
 */
@SpringBootApplication
public class TestClientApplication {

    static final List<String> NETS = List.of("net1", "net2");
    /** Spring's back-channel handler re-posts the logout token to itself with this parameter to end each session. */
    static final String INTERNAL_LOGOUT = "_spring_security_internal_logout";

    /**
     * The demo CA (SSL bundle demo-ca) becomes the JVM default trust. Spring Security builds some of its HTTP clients
     * itself: the back-channel logout-token decoder (OidcBackChannelLogoutAuthenticationProvider) news up a
     * NimbusJwtDecoder with a plain RestTemplate and its decoder factory setter is package-private. Wiring a RestClient
     * per call site cannot reach it, the default SSLContext reaches all of them (token, userinfo, JWKS, logout JWKS).
     * Runs before the security chain is built, i.e. before any HTTPS client exists.
     */
    TestClientApplication(SslBundles bundles) throws NoSuchAlgorithmException {
        SSLContext.setDefault(bundles.getBundle("demo-ca").createSslContext());
    }

    public static void main(String[] args) {
        SpringApplication.run(TestClientApplication.class, args);
    }

    static String issuer(String template, String net) {
        return template.replace("{net}", net);
    }

    static String sid(Authentication auth) {
        return auth instanceof OAuth2AuthenticationToken t && t.getPrincipal() instanceof OidcUser u
                ? u.getIdToken().getClaimAsString("sid") : null;
    }

    @Bean
    ClientRegistrationRepository registrations(@Value("${demo.issuer}") String issuerTemplate,
            @Value("${TESTCLIENT_BC_SECRET}") String bcSecret, @Value("${TESTCLIENT_FC_SECRET}") String fcSecret) {
        List<ClientRegistration> all = new ArrayList<>();
        for (String kind : List.of("bc", "fc")) {
            for (String net : NETS) {
                String iss = issuer(issuerTemplate, net), oidc = iss + "/protocol/openid-connect";
                all.add(ClientRegistration.withRegistrationId(kind + "-" + net)
                        .clientId("testclient-" + kind)
                        .clientSecret(kind.equals("bc") ? bcSecret : fcSecret)
                        .authorizationGrantType(AuthorizationGrantType.AUTHORIZATION_CODE)
                        .redirectUri("{baseUrl}/login/oauth2/code/{registrationId}")
                        .scope("openid", "tenant")
                        .clientSettings(ClientRegistration.ClientSettings.builder().requireProofKey(true).build())
                        .issuerUri(iss)
                        .authorizationUri(oidc + "/auth")
                        .tokenUri(oidc + "/token")
                        .jwkSetUri(oidc + "/certs")
                        .userInfoUri(oidc + "/userinfo")
                        .userNameAttributeName(IdTokenClaimNames.SUB)
                        .providerConfigurationMetadata(Map.of("end_session_endpoint", oidc + "/logout"))
                        .build());
            }
        }
        return new InMemoryClientRegistrationRepository(all);
    }

    /** Per HTTP session, not per user: two sessions of the same user (k6 reuses users) must not share tokens. */
    @Bean
    OAuth2AuthorizedClientRepository authorizedClients() {
        return new HttpSessionOAuth2AuthorizedClientRepository();
    }

    /** Session-destroyed events: clean the sid registry here and Spring's OIDC session registry. */
    @Bean
    HttpSessionEventPublisher sessionEvents() {
        return new HttpSessionEventPublisher();
    }

    /**
     * Refreshes through the library, logged. Keycloak gives testclient-* 60 s access tokens (70-test-apps.json);
     * refreshing 30 s before expiry means every session of 30-120 s refreshes at least once and an access token
     * reaching the resource server has >= 30 s left (no false "inactive" from expiry).
     */
    @Bean
    OAuth2AuthorizedClientManager clientManager(ClientRegistrationRepository registrations,
            OAuth2AuthorizedClientRepository authorizedClients, @Value("${demo.refresh-skew:30s}") Duration skew) {
        RefreshTokenOAuth2AuthorizedClientProvider refresh = new RefreshTokenOAuth2AuthorizedClientProvider();
        refresh.setClockSkew(skew);
        OAuth2AuthorizedClientProvider loggedRefresh = ctx -> {
            long t0 = System.nanoTime();
            String reg = ctx.getClientRegistration().getRegistrationId(), sid = sid(ctx.getPrincipal());
            try {
                OAuth2AuthorizedClient refreshed = refresh.authorize(ctx);
                if (refreshed != null) {
                    Events.log("refresh", "registration", reg, "sid", sid, "ok", true, "error", null, "latency_ms", Events.ms(t0));
                }
                return refreshed;
            }
            catch (OAuth2AuthorizationException e) {
                Events.log("refresh", "registration", reg, "sid", sid, "ok", false, "error", e.getError().getErrorCode(),
                        "latency_ms", Events.ms(t0));
                throw e;
            }
        };
        DefaultOAuth2AuthorizedClientManager manager = new DefaultOAuth2AuthorizedClientManager(registrations, authorizedClients);
        manager.setAuthorizedClientProvider(
                OAuth2AuthorizedClientProviderBuilder.builder().authorizationCode().provider(loggedRefresh).build());
        return manager;
    }

    @Bean
    SecurityFilterChain web(HttpSecurity http, ClientRegistrationRepository registrations, Sessions sessions,
            @Value("${demo.issuer}") String issuerTemplate, @Value("${demo.app-url}") String appUrl) {
        DefaultOAuth2AuthorizationRequestResolver authorize =
                new DefaultOAuth2AuthorizationRequestResolver(registrations, "/oauth2/authorization");
        authorize.setAuthorizationRequestCustomizer(b -> b.attributes(a -> {
            String id = (String) a.get(OAuth2ParameterNames.REGISTRATION_ID); // bc-net1 -> legacy-net1
            b.additionalParameters(p -> p.put("kc_idp_hint", "legacy-" + id.substring(id.indexOf('-') + 1)));
        }));
        SavedRequestAwareAuthenticationSuccessHandler afterLogin = new SavedRequestAwareAuthenticationSuccessHandler();
        OidcClientInitiatedLogoutSuccessHandler afterLogout = new OidcClientInitiatedLogoutSuccessHandler(registrations);
        afterLogout.setPostLogoutRedirectUri(appUrl + "/");

        http.authorizeHttpRequests(a -> a
                        .requestMatchers("/", "/login/*", "/frontchannel-logout", "/actuator/health", "/actuator/health/**", "/error")
                        .permitAll()
                        .anyRequest().authenticated())
                .oauth2Login(o -> o
                        .authorizationEndpoint(e -> e.authorizationRequestResolver(authorize))
                        .successHandler((req, res, auth) -> {
                            sessions.loggedIn(req, (OAuth2AuthenticationToken) auth);
                            afterLogin.onAuthenticationSuccess(req, res, auth);
                        }))
                // Spring's own back-channel endpoint /logout/connect/back-channel/{registrationId}. It ends each session
                // by POSTing the token back to itself: via localhost, not the Service name (NetworkPolicy, no hairpin).
                .oidcLogout(l -> l.backChannel(b -> b.logoutUri(
                        "{baseScheme}://localhost{basePort}/logout/connect/back-channel/{registrationId}")))
                .addFilterBefore(new BackChannelLogoutFilter(issuerTemplate), DisableEncodeUrlFilter.class)
                .logout(l -> l
                        .addLogoutHandler((req, res, auth) -> {
                            if (req.getParameter(INTERNAL_LOGOUT) == null && auth instanceof OAuth2AuthenticationToken t) {
                                Events.log("logout_initiated", "registration", t.getAuthorizedClientRegistrationId(), "sid", sid(t));
                            }
                        })
                        .logoutSuccessHandler(afterLogout))
                // ponytail: X-Frame-Options stays DENY, also on /frontchannel-logout. A browser still sends the iframe's
                // GET (the session ends), it only refuses to render the "ok". Relax it there if a test ever needs the body.
                .exceptionHandling(e -> e.authenticationEntryPoint(new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED)));
        return http.build();
    }

    /** sid -> HTTP session, for front-channel logout (Spring has no front-channel support). */
    @Component
    static class Sessions {

        private static final String SID = "demo.sid";
        private final Map<String, HttpSession> bySid = new ConcurrentHashMap<>();

        void loggedIn(HttpServletRequest req, OAuth2AuthenticationToken auth) {
            OidcUser user = (OidcUser) auth.getPrincipal();
            String sid = sid(auth);
            if (sid != null) {
                HttpSession session = req.getSession();
                session.setAttribute(SID, sid);
                bySid.put(sid, session);
            }
            Events.log("login", "registration", auth.getAuthorizedClientRegistrationId(), "sub", user.getSubject(),
                    "sid", sid, "iss", String.valueOf(user.getIssuer()));
        }

        /** Invalidates the session with this sid; false if there is none (unknown sid, or already ended). */
        boolean end(String sid) {
            HttpSession session = sid == null ? null : bySid.remove(sid);
            if (session == null) {
                return false;
            }
            try {
                session.invalidate();
            }
            catch (IllegalStateException alreadyInvalid) {
                return false;
            }
            return true;
        }

        @EventListener
        void destroyed(HttpSessionDestroyedEvent e) {
            if (e.getSession().getAttribute(SID) instanceof String sid) {
                bySid.remove(sid, e.getSession());
            }
        }
    }
}
