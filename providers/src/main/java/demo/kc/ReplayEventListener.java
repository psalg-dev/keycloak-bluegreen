package demo.kc;

import java.io.PrintStream;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.keycloak.events.Details;
import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.models.AbstractKeycloakTransaction;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;

/**
 * Writes one stdout line {"replay":true,...} per write that a lossy switch must replay onto the new color:
 * LOGOUT, REVOKE_GRANT (as a session delete) and broker user creation (REGISTER + identity_provider detail;
 * IDENTITY_PROVIDER_FIRST_LOGIN also fires for links to existing users, so it is not used).
 * The line is built in the request transaction (user + links visible) and printed only after it commits.
 */
public class ReplayEventListener implements EventListenerProvider {
    // own mapper: Keycloak's JsonSerialization drops nulls, the line keeps every key
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final List<String> ROOT_ATTRIBUTES =
            List.of(UserModel.USERNAME, UserModel.EMAIL, UserModel.FIRST_NAME, UserModel.LAST_NAME);

    private final KeycloakSession session;
    private final PrintStream out;

    public ReplayEventListener(KeycloakSession session, PrintStream out) {
        this.session = session;
        this.out = out;
    }

    @Override
    public void onEvent(Event e) {
        boolean creation = e.getType() == EventType.REGISTER
                && e.getDetails() != null && e.getDetails().containsKey(Details.IDENTITY_PROVIDER);
        if (!creation && e.getType() != EventType.LOGOUT && e.getType() != EventType.REVOKE_GRANT) return;

        Map<String, Object> line = new LinkedHashMap<>();
        line.put("replay", true);
        line.put("type", e.getType().name());
        line.put("time", e.getTime());
        line.put("realmId", e.getRealmId());
        line.put("userId", e.getUserId());
        line.put("sessionId", e.getSessionId());
        // 25 sets no sessionId on REVOKE_GRANT and detaches the client from ALL the user's sessions
        if (e.getType() == EventType.REVOKE_GRANT) line.put("clientId", e.getClientId());
        if (creation) addUser(line, e);
        printOnCommit(line);
    }

    private void addUser(Map<String, Object> line, Event e) {
        RealmModel realm = session.realms().getRealm(e.getRealmId());
        UserModel user = session.users().getUserById(realm, e.getUserId());
        Map<String, List<String>> attributes = new HashMap<>(user.getAttributes());
        attributes.keySet().removeAll(ROOT_ATTRIBUTES);
        line.put("username", user.getUsername());
        line.put("email", user.getEmail());
        line.put("firstName", user.getFirstName());
        line.put("lastName", user.getLastName());
        line.put("attributes", attributes);
        line.put("federatedIdentities", session.users().getFederatedIdentitiesStream(realm, user)
                .map(f -> {
                    // not Map.of: a null userName would throw and EventBuilder would swallow the whole line
                    Map<String, String> m = new LinkedHashMap<>();
                    m.put("identityProvider", f.getIdentityProvider());
                    m.put("userId", f.getUserId());
                    m.put("userName", f.getUserName());
                    return m;
                })
                .toList());
    }

    private void printOnCommit(Map<String, Object> line) {
        String json;
        try {
            json = JSON.writeValueAsString(line);
        } catch (JsonProcessingException ex) {
            throw new IllegalStateException(ex);
        }
        session.getTransactionManager().enlistAfterCompletion(new AbstractKeycloakTransaction() {
            @Override
            protected void commitImpl() {
                out.println(json);
            }

            @Override
            protected void rollbackImpl() {
            }
        });
    }

    @Override
    public void onEvent(AdminEvent event, boolean includeRepresentation) {
    }

    @Override
    public void close() {
    }
}
