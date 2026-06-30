package proxy

import (
    "context"
    "fmt"
    "net"
    "net/http"
    "net/http/httputil"
    "net/url"
    "time"

    "github.com/gin-gonic/gin"
    "github.com/go-redis/redis/v8"
    "proxy-vpn-extension/internal/db"
)

type Handler struct {
    DB  *db.Queries
    RDB *redis.Client
}

func (h *Handler) ProxyRequest(c *gin.Context) {
    host := c.Request.Host
    rule, err := h.DB.GetRuleByHost(context.Background(), host)
    if err != nil {
        c.JSON(http.StatusNotFound, gin.H{"error": "no route"})
        return
    }
    target, err := h.DB.GetTargetHost(context.Background(), rule.TargetHostID)
    if err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": "target not found"})
        return
    }
    if target.VpnProfileID != nil {
        status, _ := h.RDB.Get(context.Background(), "vpn:status:"+*target.VpnProfileID).Result()
        if status != "up" {
            c.JSON(http.StatusServiceUnavailable, gin.H{"error": "VPN tunnel down"})
            return
        }
    }
    remote, _ := url.Parse(fmt.Sprintf("http://%s:%d", target.PrivateIP, target.Port))
    proxy := httputil.NewSingleHostReverseProxy(remote)
    proxy.Transport = &http.Transport{
        DialContext: (&net.Dialer{
            Timeout:   10 * time.Second,
            KeepAlive: 30 * time.Second,
        }).DialContext,
    }
    proxy.ServeHTTP(c.Writer, c.Request)
}
