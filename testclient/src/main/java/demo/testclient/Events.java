package demo.testclient;

import java.text.ParseException;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.LinkedHashMap;
import java.util.Map;

import com.nimbusds.jwt.JWTParser;

import tools.jackson.databind.json.JsonMapper;

/** Contract log lines: one JSON object per line on stdout, `app`, `t`, `event` first (docs/test-apps-contract.md). */
final class Events {

    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final DateTimeFormatter T = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSSX").withZone(ZoneOffset.UTC);

    private Events() {
    }

    /** log("call", "target", "jwt", "status", 200, ...): key/value pairs, nulls kept as JSON null. */
    static void log(String event, Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("app", "testclient");
        m.put("t", T.format(Instant.now()));
        m.put("event", event);
        for (int i = 0; i < kv.length; i += 2) {
            m.put((String) kv[i], kv[i + 1]);
        }
        System.out.println(JSON.writeValueAsString(m));
    }

    static long ms(long startNanos) {
        return (System.nanoTime() - startNanos) / 1_000_000;
    }

    /** Claims of a JWT WITHOUT verifying it; only for routing and logging. Empty if it is not a JWT. */
    static Map<String, Object> unverifiedClaims(String token) {
        try {
            return token == null ? Map.of() : JWTParser.parse(token).getJWTClaimsSet().getClaims();
        }
        catch (ParseException e) {
            return Map.of();
        }
    }
}
