package demo.kc;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import org.junit.jupiter.api.Test;
import org.keycloak.events.Event;
import org.keycloak.events.EventType;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakTransaction;
import org.keycloak.models.KeycloakTransactionManager;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RealmProvider;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserProvider;
import org.keycloak.util.JsonSerialization;
import org.mockito.ArgumentCaptor;

class ReplayEventListenerTest {
    final ByteArrayOutputStream buf = new ByteArrayOutputStream();
    final KeycloakSession session = mock(KeycloakSession.class);
    final KeycloakTransactionManager tm = mock(KeycloakTransactionManager.class);
    final ReplayEventListener listener = new ReplayEventListener(session, new PrintStream(buf, true, StandardCharsets.UTF_8));

    ReplayEventListenerTest() {
        when(session.getTransactionManager()).thenReturn(tm);
    }

    static Event event(EventType type) {
        Event e = new Event();
        e.setType(type);
        e.setTime(1730000000123L);
        e.setRealmId("r1");
        e.setUserId("u1");
        e.setSessionId("s1");
        return e;
    }

    /** commits whatever the listener enlisted, returns stdout lines */
    List<String> commit() {
        ArgumentCaptor<KeycloakTransaction> tx = ArgumentCaptor.forClass(KeycloakTransaction.class);
        verify(tm, atLeast(0)).enlistAfterCompletion(tx.capture());
        tx.getAllValues().forEach(t -> { t.begin(); t.commit(); });
        String out = buf.toString(StandardCharsets.UTF_8);
        return out.isEmpty() ? List.of() : List.of(out.split("\n"));
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> json(String line) throws Exception {
        return JsonSerialization.readValue(line, Map.class);
    }

    @Test
    void logoutWritesExactlyOneReplayLineOnCommit() throws Exception {
        listener.onEvent(event(EventType.LOGOUT));
        assertEquals("", buf.toString(StandardCharsets.UTF_8), "nothing before commit");

        List<String> lines = commit();
        assertEquals(1, lines.size());
        Map<String, Object> j = json(lines.get(0));
        assertEquals(true, j.get("replay"));
        assertEquals("LOGOUT", j.get("type"));
        assertEquals(1730000000123L, ((Number) j.get("time")).longValue());
        assertEquals("r1", j.get("realmId"));
        assertEquals("u1", j.get("userId"));
        assertEquals("s1", j.get("sessionId"));
    }

    @Test
    void codeToTokenWritesNothing() {
        listener.onEvent(event(EventType.CODE_TO_TOKEN));
        assertEquals(List.of(), commit());
    }

    @Test
    void localRegistrationWithoutIdpWritesNothing() {
        listener.onEvent(event(EventType.REGISTER));
        assertEquals(List.of(), commit());
    }

    @Test
    void brokerUserCreationCarriesUserAndFederatedIdentities() throws Exception {
        RealmModel realm = mock(RealmModel.class);
        RealmProvider realms = mock(RealmProvider.class);
        when(session.realms()).thenReturn(realms);
        when(realms.getRealm("r1")).thenReturn(realm);
        UserModel user = mock(UserModel.class);
        when(user.getUsername()).thenReturn("user4500");
        when(user.getEmail()).thenReturn("user4500@legacy.example");
        when(user.getFirstName()).thenReturn("User");
        when(user.getLastName()).thenReturn("4500");
        when(user.getAttributes()).thenReturn(Map.of("tenant", List.of("t0"), "username", List.of("user4500")));
        UserProvider users = mock(UserProvider.class);
        when(session.users()).thenReturn(users);
        when(users.getUserById(realm, "u1")).thenReturn(user);
        when(users.getFederatedIdentitiesStream(realm, user))
                .thenReturn(Stream.of(new FederatedIdentityModel("legacy-net1", "user4500", "user4500")));

        Event e = event(EventType.REGISTER);
        e.setSessionId(null);
        e.setDetails(Map.of("identity_provider", "legacy-net1", "register_method", "broker"));
        listener.onEvent(e);

        List<String> lines = commit();
        assertEquals(1, lines.size());
        Map<String, Object> j = json(lines.get(0));
        assertEquals("REGISTER", j.get("type"));
        assertEquals("u1", j.get("userId"));
        assertTrue(j.containsKey("sessionId"));
        assertNull(j.get("sessionId"));
        assertEquals("user4500", j.get("username"));
        assertEquals("user4500@legacy.example", j.get("email"));
        assertEquals("User", j.get("firstName"), "replayed users keep their names (dropped before)");
        assertEquals("4500", j.get("lastName"));
        assertEquals(Map.of("tenant", List.of("t0")), j.get("attributes"), "root attrs (username, ...) stripped");
        assertEquals(List.of(Map.of("identityProvider", "legacy-net1", "userId", "user4500", "userName", "user4500")),
                j.get("federatedIdentities"));
    }

    @Test
    void revokeGrantCarriesClientId() throws Exception {
        Event e = event(EventType.REVOKE_GRANT);
        e.setClientId("k6-app");
        listener.onEvent(e);
        List<String> lines = commit();
        assertEquals(1, lines.size());
        assertEquals("k6-app", json(lines.get(0)).get("clientId"));
    }

    @Test
    void rolledBackTransactionWritesNothing() {
        listener.onEvent(event(EventType.LOGOUT));
        ArgumentCaptor<KeycloakTransaction> tx = ArgumentCaptor.forClass(KeycloakTransaction.class);
        verify(tm).enlistAfterCompletion(tx.capture());
        tx.getValue().begin();
        tx.getValue().rollback();
        assertEquals("", buf.toString(StandardCharsets.UTF_8));
    }
}
