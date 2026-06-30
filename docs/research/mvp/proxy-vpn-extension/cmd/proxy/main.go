package main

import (
    "github.com/gin-gonic/gin"
    "proxy-vpn-extension/internal/proxy"
)

func main() {
    r := gin.Default()
    // In real code, initialise DB, Redis, and handler
    // h := &proxy.Handler{...}
    // r.Any("/*path", h.ProxyRequest)
    r.Run(":8080")
}
