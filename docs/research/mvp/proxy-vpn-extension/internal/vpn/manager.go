package vpn

import (
    "context"
    "time"

    "github.com/go-redis/redis/v8"
)

type Profile struct {
    ID     string
    Name   string
    Config map[string]interface{}
}

type Manager struct {
    rdb      *redis.Client
    profiles map[string]*Profile
}

func NewManager(rdb *redis.Client) *Manager {
    return &Manager{
        rdb:      rdb,
        profiles: make(map[string]*Profile),
    }
}

func (m *Manager) ApplyProfile(p Profile) error {
    // In production: create WireGuard tunnel device, add routes, etc.
    m.profiles[p.ID] = &p
    ctx := context.Background()
    m.rdb.Set(ctx, "vpn:status:"+p.ID, "up", 15*time.Second)
    m.rdb.Publish(ctx, "vpn:events", `{"profile_id":"`+p.ID+`","status":"up"}`)
    return nil
}

func (m *Manager) RemoveProfile(id string) error {
    delete(m.profiles, id)
    ctx := context.Background()
    m.rdb.Set(ctx, "vpn:status:"+id, "down", 15*time.Second)
    m.rdb.Publish(ctx, "vpn:events", `{"profile_id":"`+id+`","status":"down"}`)
    return nil
}
