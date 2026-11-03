package demo.testclient;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpTimeoutException;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ssl.SslBundles;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.security.oauth2.client.OAuth2AuthorizeRequest;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClient;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientManager;
import org.springframework.security.oauth2.client.authentication.OAuth2AuthenticationToken;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.oauth2.client.web.OAuth2AuthorizedClientRepository;
import org.springframework.security.oauth2.core.OAuth2AuthorizationException;
import org.springframework.security.oauth2.core.oidc.user.OidcUser;
import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

@RestController
class Endpoints {

    private final ClientRegistrationRepository registrations;
    private final OAuth2AuthorizedClientRepository authorizedClients;
    private final OAuth2AuthorizedClientManager clientManager;
    private final TestClientApplication.Sessions sessions;
    private final RestClient api;

    Endpoints(ClientRegistrationRepository registrations, OAuth2AuthorizedClientRepository authorizedClients,
            OAuth2AuthorizedClientManager clientManager, TestClientApplication.Sessions sessions, SslBundles bundles,
            @Value("${demo.api}") String apiUrl) {
        this.registrations = registrations;
        this.authorizedClients = authorizedClients;
        this.clientManager = clientManager;
        this.sessions = sessions;
        JdkClientHttpRequestFactory http = new JdkClientHttpRequestFactory(HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .sslContext(bundles.getBundle("demo-ca").createSslContext())
                .build());
        http.setReadTimeout(Duration.ofSeconds(10));
        this.api = RestClient.builder().baseUrl(apiUrl).requestFactory(http).build();
    }

    /** Landing page after login and after logout (post_logout_redirect_uri). */
    @GetMapping(value = "/", produces = MediaType.TEXT_PLAIN_VALUE)
    String home() {
        return "testclient";
    }

    @GetMapping("/login/{registrationId}")
    ResponseEntity<Void> login(@PathVariable String registrationId) {
        if (registrations.findByRegistrationId(registrationId) == null) {
            return ResponseEntity.notFound().build(); // Spring would answer 500 for an unknown registration
        }
        return ResponseEntity.status(302).location(URI.create("/oauth2/authorization/" + registrationId)).build();
    }

    /** Who is logged in. The CSRF token for POST /logout travels in a header, so k6 needs no HTML. */
    @GetMapping("/me")
    Map<String, Object> me(OAuth2AuthenticationToken auth, CsrfToken csrf, HttpServletResponse res) {
        res.setHeader("X-CSRF-TOKEN", csrf.getToken());
        OidcUser user = (OidcUser) auth.getPrincipal();
        Map<String, Object> me = new LinkedHashMap<>();
        me.put("sub", user.getSubject());
        me.put("iss", String.valueOf(user.getIssuer()));
        me.put("sid", TestClientApplication.sid(auth));
        me.put("registration", auth.getAuthorizedClientRegistrationId());
        me.put("login_ctx", user.getClaims().get("login_ctx"));
        me.put("tenant", user.getClaims().get("tenant"));
        return me;
    }

    /**
     * Calls the resource server with the session's access token, refreshed by the client manager when due.
     * status: the upstream status when the call was made; 401 when the token could not be (re)obtained (refresh
     * invalid_grant = Keycloak lost the session; re-authentication is NOT automatic); 502 when the resource server
     * was unreachable (upstream_status 0).
     */
    @GetMapping("/call/{target}")
    ResponseEntity<Map<String, Object>> call(@PathVariable String target, OAuth2AuthenticationToken auth,
            HttpServletRequest req, HttpServletResponse res) {
        if (!target.equals("jwt") && !target.equals("introspect")) {
            return ResponseEntity.notFound().build();
        }
        long t0 = System.nanoTime();
        String registration = auth.getAuthorizedClientRegistrationId();
        Integer upstream = null;
        boolean refreshed = false;
        String error = null;
        int status;
        try {
            OAuth2AuthorizedClient before = authorizedClients.loadAuthorizedClient(registration, auth, req);
            OAuth2AuthorizedClient client = clientManager.authorize(OAuth2AuthorizeRequest
                    .withClientRegistrationId(registration).principal(auth)
                    .attribute(HttpServletRequest.class.getName(), req)
                    .attribute(HttpServletResponse.class.getName(), res)
                    .build());
            refreshed = before != null && client.getAccessToken() != before.getAccessToken();
            upstream = api.get().uri("/api/" + target)
                    .headers(h -> h.setBearerAuth(client.getAccessToken().getTokenValue()))
                    .exchange((rq, rs) -> rs.getStatusCode().value());
            status = upstream;
            error = upstream == 200 ? null : "upstream_" + upstream;
        }
        catch (OAuth2AuthorizationException e) { // refresh failed, or no authorized client left after an earlier failure
            status = 401;
            error = e.getError().getErrorCode();
        }
        catch (RestClientException e) {
            status = 502;
            upstream = 0;
            error = e.getMostSpecificCause() instanceof HttpTimeoutException ? "timeout" : "connect";
        }
        Events.log("call", "target", target, "status", status, "upstream_status", upstream, "refreshed", refreshed,
                "latency_ms", Events.ms(t0), "error", error, "sid", TestClientApplication.sid(auth),
                "registration", registration);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", status);
        body.put("upstream_status", upstream);
        body.put("refreshed", refreshed);
        body.put("error", error);
        return ResponseEntity.status(status).body(body);
    }

    /** Keycloak's front-channel logout (iframe on its logout page): end the local session with that sid. */
    @GetMapping(value = "/frontchannel-logout", produces = MediaType.TEXT_PLAIN_VALUE)
    String frontChannelLogout(@RequestParam(required = false) String iss, @RequestParam(required = false) String sid) {
        boolean found = sessions.end(sid);
        Events.log("frontchannel_logout", "sid", sid, "iss", iss, "found_session", found);
        return "ok";
    }
}
