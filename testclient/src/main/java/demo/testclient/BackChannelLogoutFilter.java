package demo.testclient;

import java.io.IOException;
import java.util.Map;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.util.ContentCachingResponseWrapper;
import org.springframework.web.util.ServletRequestPathUtils;

import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

/**
 * In front of Spring's back-channel logout endpoint: logs every delivery from Keycloak (`backchannel_logout`) and
 * routes the alias `/logout/connect/back-channel/bc`.
 * <p>
 * Why the alias: one Keycloak client (testclient-bc) has ONE back-channel URL, but serves two Spring registrations
 * (bc-net1, bc-net2) whose issuers differ. Spring validates the logout token against the registration in the path, so
 * a net2 session's token posted to .../bc-net1 fails the iss check. Keycloak calls .../bc; the token's (unverified) iss
 * picks bc-netN here, and Spring then verifies the token against that registration as usual.
 */
class BackChannelLogoutFilter extends OncePerRequestFilter {

    static final String PATH = "/logout/connect/back-channel/";
    private static final JsonMapper JSON = JsonMapper.builder().build();

    private final String issuerTemplate;

    BackChannelLogoutFilter(String issuerTemplate) {
        this.issuerTemplate = issuerTemplate;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !"POST".equals(request.getMethod()) || !request.getRequestURI().startsWith(PATH)
                || request.getParameter(TestClientApplication.INTERNAL_LOGOUT) != null; // Spring's own loopback call
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        long t0 = System.nanoTime();
        Map<String, Object> claims = Events.unverifiedClaims(request.getParameter("logout_token"));
        String iss = (String) claims.get("iss");
        String registration = request.getRequestURI().substring(PATH.length());
        if (registration.equals("bc")) {
            for (String net : TestClientApplication.NETS) {
                if (TestClientApplication.issuer(issuerTemplate, net).equals(iss)) {
                    registration = "bc-" + net;
                    request = withUri(request, PATH + registration);
                }
            }
        }
        ContentCachingResponseWrapper res = new ContentCachingResponseWrapper(response);
        String error = null;
        try {
            chain.doFilter(request, res);
            if (res.getStatus() != 200) {
                error = error(res.getContentAsByteArray(), res.getStatus());
            }
        }
        catch (RuntimeException | ServletException | IOException e) {
            error = e.getClass().getSimpleName() + ": " + e.getMessage();
            throw e;
        }
        finally {
            Events.log("backchannel_logout", "registration", registration, "sid", claims.get("sid"), "sub", claims.get("sub"),
                    "iss", iss, "ok", error == null, "error", error, "latency_ms", Events.ms(t0));
            res.copyBodyToResponse();
        }
    }

    /** Spring answers failures with an OAuth2 error body: {"error":..,"error_description":..}. */
    private static String error(byte[] body, int status) {
        try {
            JsonNode n = JSON.readTree(body);
            String d = n.path("error_description").asString(null);
            return d != null ? d : n.path("error").asString("http_" + status);
        }
        catch (RuntimeException notJson) {
            return "http_" + status;
        }
    }

    private static HttpServletRequest withUri(HttpServletRequest request, String uri) {
        ServletRequestPathUtils.clearParsedRequestPath(request); // a path parsed earlier would win over the new URI
        return new HttpServletRequestWrapper(request) {
            @Override
            public String getRequestURI() {
                return uri;
            }

            @Override
            public String getServletPath() {
                return uri;
            }

            @Override
            public StringBuffer getRequestURL() {
                StringBuffer url = super.getRequestURL();
                return new StringBuffer(url.substring(0, url.length() - super.getRequestURI().length()) + uri);
            }
        };
    }
}
