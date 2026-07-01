// HTTP handlers for the control-API (design spec §4 component 4, §11 ③⑤⑥): REST
// CRUD over the store entities, the SSE live-event stream, and the PAC endpoint.
// Every mutation (PUT/DELETE) is recorded in audit_log via the store (spec §12);
// the actor is the verified mTLS client-cert CommonName (the request reached a
// handler only because the TLS layer already verified that identity — fail-closed).
//
// JSON DTOs decouple the wire shape from the store row types (notably
// VPNProfile.Config []byte is exposed as a raw JSON object, not base64). Input is
// validated before any store write; invalid input is a 400, never a partial write.
package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"digital.vasic.helixproxy/controlplane/internal/pac"
	"digital.vasic.helixproxy/controlplane/internal/store"
)

// --- DTOs -------------------------------------------------------------------

type profileDTO struct {
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name"`
	Type      string          `json:"type,omitempty"`
	Config    json.RawMessage `json:"config,omitempty"`
	SecretRef string          `json:"secret_ref,omitempty"`
	Enabled   bool            `json:"enabled"`
}

type targetDTO struct {
	ID           string `json:"id,omitempty"`
	PublicAlias  string `json:"public_alias"`
	PrivateIP    string `json:"private_ip"`
	Port         int    `json:"port,omitempty"`
	Protocol     string `json:"protocol,omitempty"`
	VPNProfileID string `json:"vpn_profile_id,omitempty"`
	HealthCheck  string `json:"health_check,omitempty"`
	Enabled      bool   `json:"enabled"`
}

type ruleDTO struct {
	ID           string `json:"id,omitempty"`
	Priority     int    `json:"priority"`
	MatchHost    string `json:"match_host,omitempty"`
	MatchPath    string `json:"match_path,omitempty"`
	TargetHostID string `json:"target_host_id,omitempty"`
	Enabled      bool   `json:"enabled"`
}

type tierDTO struct {
	TargetID     string `json:"target_id"`
	VPNProfileID string `json:"vpn_profile_id"`
	Tier         int    `json:"tier"`
}

type userDTO struct {
	ID        string `json:"id,omitempty"`
	Username  string `json:"username"`
	SecretRef string `json:"secret_ref,omitempty"`
	Role      string `json:"role,omitempty"`
	Enabled   bool   `json:"enabled"`
}

func profileToDTO(p store.VPNProfile) profileDTO {
	d := profileDTO{ID: p.ID, Name: p.Name, Type: string(p.Type), SecretRef: p.SecretRef, Enabled: p.Enabled}
	if len(p.Config) > 0 {
		d.Config = json.RawMessage(p.Config)
	}
	return d
}

func targetToDTO(t store.TargetHost) targetDTO {
	return targetDTO{ID: t.ID, PublicAlias: t.PublicAlias, PrivateIP: t.PrivateIP, Port: t.Port,
		Protocol: t.Protocol, VPNProfileID: t.VPNProfileID, HealthCheck: t.HealthCheck, Enabled: t.Enabled}
}

func ruleToDTO(r store.ProxyRule) ruleDTO {
	return ruleDTO{ID: r.ID, Priority: r.Priority, MatchHost: r.MatchHost, MatchPath: r.MatchPath,
		TargetHostID: r.TargetHostID, Enabled: r.Enabled}
}

func userToDTO(u store.ProxyUser) userDTO {
	return userDTO{ID: u.ID, Username: u.Username, SecretRef: u.SecretRef, Role: u.Role, Enabled: u.Enabled}
}

// --- helpers ----------------------------------------------------------------

// actorFromRequest returns the verified mTLS client identity (cert CN). mTLS
// guarantees a verified peer cert reached the handler; "" is the safe fallback.
func actorFromRequest(r *http.Request) string {
	if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
		if cn := r.TLS.PeerCertificates[0].Subject.CommonName; cn != "" {
			return cn
		}
	}
	return "unknown"
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func decodeJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	return nil
}

// auditEntry builds the audit row for a control-plane mutation. The actor is the
// verified mTLS client-cert CN; detail is JSON-marshalled (a marshal error yields
// "" → normalised to {} by the store, never a partial write).
func auditEntry(r *http.Request, action string, detail any) store.AuditLogEntry {
	db, _ := json.Marshal(detail)
	return store.AuditLogEntry{Actor: actorFromRequest(r), Action: action, Detail: string(db)}
}

// mutateWithAudit runs an entity mutation and its audit append inside ONE store
// transaction (store.WithTx). This closes P6 WARNING-4: every mutating handler used
// to do two separate store calls — `mutate (Upsert*/Delete*)` THEN `AppendAudit` —
// so if the mutation committed and AppendAudit then failed, the handler returned 500
// yet the mutation was already durable: an un-audited mutation (proven on the pre-fix
// artifact by TestAtomicity_MutationAndAuditCommitTogether, RED_MODE=1). Wrapping the
// pair in WithTx makes them atomic: a failed audit rolls the mutation back, so an
// un-audited mutation is impossible. The STORE owns begin/commit/rollback; the handler
// only composes the two operations inside the transaction boundary (it never holds a
// transaction it cannot roll back). mutate receives the tx-scoped store and returns the
// audit row to append; both run on the same tx.
func (s *server) mutateWithAudit(r *http.Request, mutate func(tx store.Queries) (store.AuditLogEntry, error)) error {
	return s.q.WithTx(r.Context(), func(tx store.Queries) error {
		entry, err := mutate(tx)
		if err != nil {
			return err // mutation error returns UNWRAPPED so errors.Is(…, ErrNotFound) still maps to 404
		}
		if err := tx.AppendAudit(r.Context(), entry); err != nil {
			return fmt.Errorf("audit write failed: %w", err)
		}
		return nil
	})
}

// --- profiles ---------------------------------------------------------------

func (s *server) listProfiles(w http.ResponseWriter, r *http.Request) {
	ps, err := s.q.ListProfiles(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]profileDTO, 0, len(ps))
	for _, p := range ps {
		out = append(out, profileToDTO(p))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) getProfile(w http.ResponseWriter, r *http.Request) {
	p, err := s.q.GetProfile(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "profile not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, profileToDTO(p))
}

func (s *server) putProfile(w http.ResponseWriter, r *http.Request) {
	var d profileDTO
	if err := decodeJSON(r, &d); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if strings.TrimSpace(d.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	switch store.VPNType(d.Type) {
	case "", store.VPNTypeWireGuard, store.VPNTypeOpenVPN, store.VPNTypeLegacy:
	default:
		writeErr(w, http.StatusBadRequest, "type must be wireguard|openvpn|legacy")
		return
	}
	if len(d.Config) > 0 && !json.Valid(d.Config) {
		writeErr(w, http.StatusBadRequest, "config must be a valid JSON object")
		return
	}
	var id string
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		var e error
		id, e = tx.UpsertProfile(r.Context(), store.VPNProfile{
			Name: d.Name, Type: store.VPNType(d.Type), Config: []byte(d.Config),
			SecretRef: d.SecretRef, Enabled: d.Enabled,
		})
		if e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "profile.upsert", map[string]string{"id": id, "name": d.Name}), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
}

func (s *server) deleteProfile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		if e := tx.DeleteProfile(r.Context(), id); e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "profile.delete", map[string]string{"id": id}), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- targets ----------------------------------------------------------------

func (s *server) listTargets(w http.ResponseWriter, r *http.Request) {
	ts, err := s.q.ListTargets(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]targetDTO, 0, len(ts))
	for _, t := range ts {
		out = append(out, targetToDTO(t))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) getTarget(w http.ResponseWriter, r *http.Request) {
	t, err := s.q.GetTargetHost(r.Context(), r.PathValue("alias"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "target not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, targetToDTO(t))
}

func (s *server) putTarget(w http.ResponseWriter, r *http.Request) {
	var d targetDTO
	if err := decodeJSON(r, &d); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if strings.TrimSpace(d.PublicAlias) == "" {
		writeErr(w, http.StatusBadRequest, "public_alias is required")
		return
	}
	if strings.TrimSpace(d.PrivateIP) == "" {
		writeErr(w, http.StatusBadRequest, "private_ip is required")
		return
	}
	if d.Port < 0 || d.Port > 65535 {
		writeErr(w, http.StatusBadRequest, "port must be 0..65535")
		return
	}
	var id string
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		var e error
		id, e = tx.UpsertTarget(r.Context(), store.TargetHost{
			PublicAlias: d.PublicAlias, PrivateIP: d.PrivateIP, Port: d.Port, Protocol: d.Protocol,
			VPNProfileID: d.VPNProfileID, HealthCheck: d.HealthCheck, Enabled: d.Enabled,
		})
		if e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "target.upsert", map[string]string{"id": id, "public_alias": d.PublicAlias}), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
}

func (s *server) deleteTarget(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		if e := tx.DeleteTarget(r.Context(), id); e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "target.delete", map[string]string{"id": id}), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- rules ------------------------------------------------------------------

func (s *server) listRules(w http.ResponseWriter, r *http.Request) {
	rs, err := s.q.ListRules(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]ruleDTO, 0, len(rs))
	for _, x := range rs {
		out = append(out, ruleToDTO(x))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) getRuleByHost(w http.ResponseWriter, r *http.Request) {
	x, err := s.q.GetRuleByHost(r.Context(), r.PathValue("host"))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "no enabled rule for host")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, ruleToDTO(x))
}

func (s *server) putRule(w http.ResponseWriter, r *http.Request) {
	var d ruleDTO
	if err := decodeJSON(r, &d); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if d.MatchHost == "" && d.MatchPath == "" {
		writeErr(w, http.StatusBadRequest, "at least one of match_host / match_path is required")
		return
	}
	var id string
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		var e error
		id, e = tx.UpsertRule(r.Context(), store.ProxyRule{
			ID: d.ID, Priority: d.Priority, MatchHost: d.MatchHost, MatchPath: d.MatchPath,
			TargetHostID: d.TargetHostID, Enabled: d.Enabled,
		})
		if e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "rule.upsert", map[string]any{"id": id, "priority": d.Priority, "match_host": d.MatchHost}), nil
	})
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "rule id not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
}

func (s *server) deleteRule(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		if e := tx.DeleteRule(r.Context(), id); e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "rule.delete", map[string]string{"id": id}), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- tiers ------------------------------------------------------------------

func (s *server) listTiers(w http.ResponseWriter, r *http.Request) {
	ts, err := s.q.ListTiers(r.Context(), r.PathValue("targetID"))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]tierDTO, 0, len(ts))
	for _, t := range ts {
		out = append(out, tierDTO{TargetID: t.TargetID, VPNProfileID: t.VPNProfileID, Tier: t.Tier})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) putTier(w http.ResponseWriter, r *http.Request) {
	var d tierDTO
	if err := decodeJSON(r, &d); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if d.TargetID == "" || d.VPNProfileID == "" {
		writeErr(w, http.StatusBadRequest, "target_id and vpn_profile_id are required")
		return
	}
	if d.Tier < 0 {
		writeErr(w, http.StatusBadRequest, "tier must be >= 0")
		return
	}
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		if e := tx.UpsertTier(r.Context(), store.TargetTunnelTier{
			TargetID: d.TargetID, VPNProfileID: d.VPNProfileID, Tier: d.Tier,
		}); e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "tier.upsert", d), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) deleteTier(w http.ResponseWriter, r *http.Request) {
	targetID := r.PathValue("targetID")
	tier, err := strconv.Atoi(r.PathValue("tier"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "tier must be an integer")
		return
	}
	err = s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		if e := tx.DeleteTier(r.Context(), targetID, tier); e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "tier.delete", map[string]any{"target_id": targetID, "tier": tier}), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- users ------------------------------------------------------------------

func (s *server) listUsers(w http.ResponseWriter, r *http.Request) {
	us, err := s.q.ListUsers(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := make([]userDTO, 0, len(us))
	for _, u := range us {
		out = append(out, userToDTO(u))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *server) putUser(w http.ResponseWriter, r *http.Request) {
	var d userDTO
	if err := decodeJSON(r, &d); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON: "+err.Error())
		return
	}
	if strings.TrimSpace(d.Username) == "" {
		writeErr(w, http.StatusBadRequest, "username is required")
		return
	}
	var id string
	err := s.mutateWithAudit(r, func(tx store.Queries) (store.AuditLogEntry, error) {
		var e error
		id, e = tx.UpsertUser(r.Context(), store.ProxyUser{
			Username: d.Username, SecretRef: d.SecretRef, Role: d.Role, Enabled: d.Enabled,
		})
		if e != nil {
			return store.AuditLogEntry{}, e
		}
		return auditEntry(r, "user.upsert", map[string]string{"id": id, "username": d.Username}), nil
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
}

// --- SSE live events --------------------------------------------------------

// events forwards Redis vpn:events to the client as Server-Sent Events. Each event
// is one `data: <json>\n\n` frame, flushed immediately. The stream ends cleanly
// when the client disconnects (r.Context() cancelled) or the subscription drops.
func (s *server) events(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	ch, err := s.bus.SubscribeEvents(r.Context())
	if err != nil {
		writeErr(w, http.StatusBadGateway, "event bus unavailable: "+err.Error())
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher.Flush() // commit headers so the client sees the open stream immediately

	for {
		select {
		case <-r.Context().Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return // subscription closed (ctx ended or dropped)
			}
			b, err := json.Marshal(ev)
			if err != nil {
				continue
			}
			if _, err := fmt.Fprintf(w, "data: %s\n\n", b); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// --- PAC --------------------------------------------------------------------

// proxyPAC serves the FindProxyForURL artifact built from the enabled targets.
// Deterministic: enabled aliases map to the proxy, everything else DIRECT.
func (s *server) proxyPAC(w http.ResponseWriter, r *http.Request) {
	targets, err := s.q.ListTargets(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	entries := make([]pac.Entry, 0, len(targets))
	for _, t := range targets {
		if t.Enabled {
			entries = append(entries, pac.Entry{HostGlob: t.PublicAlias, Proxy: pac.DefaultProxy})
		}
	}
	body, err := s.gen.Generate(r.Context(), entries)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	// PAC is JavaScript (a FindProxyForURL function); served as text/javascript per
	// spec §11 ⑤. Clients also accept application/x-ns-proxy-autoconfig.
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = w.Write(body)
}
