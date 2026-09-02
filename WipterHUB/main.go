package main

import (
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	mathRand "math/rand"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/net/proxy"
)

const (
	COGNITO_CLIENT_ID = "4isku1tmrioog84a88qkl7cnd4"
	COGNITO_DOMAIN    = "https://auth.wipter.com"
	REDIRECT_URI      = "http://localhost:7777/callback"
	AUTH_SCOPE        = "email openid https://ppc-production-resource-server/ws-api-read https://ppc-production-resource-server/metrics-service-read https://ppc-production-resource-server/user-service-read"
	WIPTER_STOMP_URL  = "wss://ch.wipter.com/stomp-endpoint/websocket"
	FRPC_TOKEN        = "nZ7wP25ETgQaq9eKA6b4JR"
	FRPC_SERVER_PORT  = "10000"
	STATE_FILE        = "devices_state.json"
	DIAGNOSTIC_ADDR_DEFAULT = "127.0.0.1:28999"
)

const (
	ZONE_GREEN  int32 = 0
	ZONE_YELLOW int32 = 1
	ZONE_ORANGE int32 = 2
	ZONE_RED    int32 = 3
)

var (
	currentPressureZone int32 = ZONE_YELLOW
	totalHostRAM_MB     int64 = 2048
	availHostRAM_MB     int64 = 1024
)

var (
	pool4K = sync.Pool{
		New: func() interface{} {
			b := make([]byte, 4*1024)
			return &b
		},
	}
	pool16K = sync.Pool{
		New: func() interface{} {
			b := make([]byte, 16*1024)
			return &b
		},
	}
	pool32K = sync.Pool{
		New: func() interface{} {
			b := make([]byte, 32*1024)
			return &b
		},
	}
	pool64K = sync.Pool{
		New: func() interface{} {
			b := make([]byte, 64*1024)
			return &b
		},
	}
)

func getDynamicBuffer() *[]byte {
	zone := atomic.LoadInt32(&currentPressureZone)
	switch zone {
	case ZONE_GREEN:
		return pool64K.Get().(*[]byte)
	case ZONE_YELLOW:
		return pool32K.Get().(*[]byte)
	case ZONE_ORANGE:
		return pool16K.Get().(*[]byte)
	default:
		return pool4K.Get().(*[]byte)
	}
}

func putDynamicBuffer(b *[]byte) {
	if b == nil {
		return
	}
	c := cap(*b)
	switch {
	case c >= 64*1024:
		pool64K.Put(b)
	case c >= 32*1024:
		pool32K.Put(b)
	case c >= 16*1024:
		pool16K.Put(b)
	default:
		pool4K.Put(b)
	}
}

func startDynamicResourceGovernor(ctx context.Context) {
	numCPU := runtime.NumCPU()
	runtime.GOMAXPROCS(numCPU)

	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			memData, err := os.ReadFile("/proc/meminfo")
			if err != nil {
				continue
			}

			var totalKB, availKB int64
			for _, line := range strings.Split(string(memData), "\n") {
				if strings.HasPrefix(line, "MemTotal:") {
					fmt.Sscanf(line, "MemTotal: %d kB", &totalKB)
				} else if strings.HasPrefix(line, "MemAvailable:") {
					fmt.Sscanf(line, "MemAvailable: %d kB", &availKB)
				}
			}

			if totalKB <= 0 {
				continue
			}

			totalMB := totalKB / 1024
			availMB := availKB / 1024
			atomic.StoreInt64(&totalHostRAM_MB, totalMB)
			atomic.StoreInt64(&availHostRAM_MB, availMB)

			freeRatio := float64(availKB) / float64(totalKB)

			switch {
			case freeRatio > 0.45:
				if atomic.SwapInt32(&currentPressureZone, ZONE_GREEN) != ZONE_GREEN {
					debug.SetGCPercent(50)
				}
			case freeRatio > 0.30:
				if atomic.SwapInt32(&currentPressureZone, ZONE_YELLOW) != ZONE_YELLOW {
					debug.SetGCPercent(30)
				}
			case freeRatio > 0.15:
				if atomic.SwapInt32(&currentPressureZone, ZONE_ORANGE) != ZONE_ORANGE {
					debug.SetGCPercent(15)
					debug.FreeOSMemory()
				}
			default:
				atomic.StoreInt32(&currentPressureZone, ZONE_RED)
				debug.SetGCPercent(10)
				runtime.GC()
				debug.FreeOSMemory()
			}
		case <-ctx.Done():
			return
		}
	}
}

var (
	totalNodesLoaded int32
	onlineNodesCount int32
	isolatedDeadNode int32
	accumulatedBytes uint64
	activeConnections int32
)

var (
	maxConnPerNode     = 32
	maxConnGlobal      = 2000
	bridgeIdleTimeout  = 120 * time.Second
	blockPrivateTarget = true
	globalConnSem      = make(chan struct{}, 2000)
)

func getEnvBool(key string, fallback bool) bool {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if v == "" {
		return fallback
	}
	switch v {
	case "1", "true", "yes", "y", "on":
		return true
	case "0", "false", "no", "n", "off":
		return false
	default:
		return fallback
	}
}

func getEnvInt(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func tryAcquire(sem chan struct{}) bool {
	select {
	case sem <- struct{}{}:
		return true
	default:
		return false
	}
}

func releaseSem(sem chan struct{}) {
	select {
	case <-sem:
	default:
	}
}

type NodeDiagnosticInfo struct {
	ID                int    `json:"id"`
	ProxyHost         string `json:"proxy_host"`
	DeviceName        string `json:"device_name"`
	Status            string `json:"status"`
	StatusSince       string `json:"status_since"`
	UpdatedAt         string `json:"updated_at"`
	RelayBytes        uint64 `json:"relay_bytes"`
	RelayMB           string `json:"relay_mb"`
	LastError         string `json:"last_error"`
	LastErrorCode     string `json:"last_error_code"`
	LastErrorAt       string `json:"last_error_at"`
	ConnectedAt       string `json:"connected_at"`
	ActiveConnections int32  `json:"active_connections"`
	LocalBridgePort   int    `json:"local_bridge_port"`
	RelayIP           string `json:"relay_ip"`
	TunnelRestarts    uint64 `json:"tunnel_restarts"`
	FailCount         int    `json:"fail_count"`
}

type NodeRegistry struct {
	mu    sync.RWMutex
	nodes map[int]*NodeDiagnosticInfo
}

var globalRegistry = &NodeRegistry{nodes: make(map[int]*NodeDiagnosticInfo)}

var errorCodePattern = regexp.MustCompile(`^\[([^\]]+)\]`)

func nowStamp() string {
	return time.Now().Format("2006-01-02 15:04:05")
}

func extractErrorCode(msg string) string {
	if m := errorCodePattern.FindStringSubmatch(msg); len(m) == 2 {
		return m[1]
	}
	return ""
}

func (r *NodeRegistry) Update(id int, host, device, status, lastErr string, addBytes uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	n, exists := r.nodes[id]
	if !exists {
		n = &NodeDiagnosticInfo{ID: id, ProxyHost: host, DeviceName: device, StatusSince: nowStamp()}
		r.nodes[id] = n
	}
	if host != "" {
		n.ProxyHost = host
	}
	if device != "" {
		n.DeviceName = device
	}
	if status != "" && status != n.Status {
		n.Status = status
		n.StatusSince = nowStamp()
		if status == "ONLINE" && n.ConnectedAt == "" {
			n.ConnectedAt = time.Now().Format("15:04:05")
		} else if status != "ONLINE" {
			n.ConnectedAt = ""
		}
	}
	if lastErr != "" {
		cleanErr := strings.ReplaceAll(lastErr, "\x00", "")
		cleanErr = strings.ReplaceAll(cleanErr, "\n", " ")
		cleanErr = strings.ReplaceAll(cleanErr, "\r", "")
		n.LastError = strings.TrimSpace(cleanErr)
		n.LastErrorCode = extractErrorCode(n.LastError)
		n.LastErrorAt = nowStamp()
	}
	if addBytes > 0 {
		n.RelayBytes += addBytes
		n.RelayMB = fmt.Sprintf("%.2f", float64(n.RelayBytes)/(1024*1024))
	}
	n.UpdatedAt = nowStamp()
}

func (r *NodeRegistry) UpdateRuntime(id int, activeConns int32, localPort int, relayIP string, tunnelRestarts uint64, failCount int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	n, exists := r.nodes[id]
	if !exists {
		n = &NodeDiagnosticInfo{ID: id, StatusSince: nowStamp()}
		r.nodes[id] = n
	}
	n.ActiveConnections = activeConns
	n.LocalBridgePort = localPort
	n.RelayIP = relayIP
	n.TunnelRestarts = tunnelRestarts
	n.FailCount = failCount
	n.UpdatedAt = nowStamp()
}

type SafeWSConn struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func (s *SafeWSConn) WriteMessage(messageType int, data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn == nil {
		return fmt.Errorf("socket is nil")
	}
	return s.conn.WriteMessage(messageType, data)
}

func (s *SafeWSConn) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != nil {
		err := s.conn.Close()
		s.conn = nil
		return err
	}
	return nil
}

type DeviceProfile struct {
	DeviceID   string `json:"device_id"`
	Hostname   string `json:"hostname"`
	OS         string `json:"os"`
	Platform   string `json:"platform"`
	CPUCores   int    `json:"cpu_cores"`
	MemoryMB   int    `json:"memory_mb"`
	MACAddr    string `json:"mac_address"`
	Resolution string `json:"resolution"`
	GPUDesc    string `json:"gpu_desc"`
	AppVer     string `json:"app_version"`
}

type NodeSession struct {
	ID             int
	RawProxy       string
	Profile        DeviceProfile
	FailCount      int
	Dialer         proxy.Dialer
	SafeWS         *SafeWSConn
	IsOnline       bool
	cancel         context.CancelFunc
	bridgeListener net.Listener
	tunnelCmd      *exec.Cmd
	tunnelCancel   context.CancelFunc
	connSem        chan struct{}
	activeConns    int32
	localPort      int
	relayIP        string
	tunnelRestarts uint64
	tunnelLock     sync.Mutex
	mu             sync.Mutex
}

type StateManager struct {
	mu      sync.Mutex
	Devices map[string]DeviceProfile `json:"devices"`
}

func LoadStateManager() *StateManager {
	sm := &StateManager{Devices: make(map[string]DeviceProfile)}
	data, err := os.ReadFile(STATE_FILE)
	if err == nil && len(strings.TrimSpace(string(data))) > 0 {
		// Backward compatible loader: older versions saved a bare proxy-keyed map,
		// while StateManager itself declares a {"devices": ...} envelope.
		var wrapped struct {
			Devices map[string]DeviceProfile `json:"devices"`
		}
		if json.Unmarshal(data, &wrapped) == nil && len(wrapped.Devices) > 0 {
			sm.Devices = wrapped.Devices
		} else {
			_ = json.Unmarshal(data, &sm.Devices)
		}
	}
	return sm
}

func (sm *StateManager) Save() {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	data, err := json.MarshalIndent(struct {
		Devices map[string]DeviceProfile `json:"devices"`
	}{Devices: sm.Devices}, "", "  ")
	if err != nil {
		return
	}

	tmpFile := STATE_FILE + ".tmp"
	if err := os.WriteFile(tmpFile, data, 0644); err == nil {
		os.Rename(tmpFile, STATE_FILE)
	}
}

func stateKeyForProxy(proxyStr string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(proxyStr)))
	return "proxy_sha256:" + hex.EncodeToString(sum[:])
}

func (sm *StateManager) GetOrGenerate(proxyStr string, index int) DeviceProfile {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	stateKey := stateKeyForProxy(proxyStr)
	if p, ok := sm.Devices[stateKey]; ok && p.DeviceID != "" {
		return p
	}
	// Legacy fallback for state files created before proxy keys were hashed.
	if p, ok := sm.Devices[proxyStr]; ok && p.DeviceID != "" {
		delete(sm.Devices, proxyStr)
		sm.Devices[stateKey] = p
		return p
	}

	hasher := md5.New()
	hasher.Write([]byte(fmt.Sprintf("wipter-entropy-v12-%s-%d", strings.TrimSpace(proxyStr), index)))
	h := hex.EncodeToString(hasher.Sum(nil))

	ouis := []string{"00:1B:21", "00:E0:4C", "00:14:22", "3C:D9:2B", "70:85:C2", "B8:27:EB"}
	resolutions := []string{"1920x1080", "2560x1440", "1366x768", "1920x1200"}
	osList := []string{"Windows 10 Pro 64-bit", "Windows 11 Pro 64-bit", "Ubuntu 22.04.4 LTS", "macOS Sonoma 14.4"}
	cores := []int{4, 6, 8, 12, 16}
	mems := []int{8192, 16384, 32768}

	rawIDBytes, _ := hex.DecodeString(h)
	hb := int(rawIDBytes[0])
	osChoice := osList[hb%len(osList)]
	plat := "win32"
	gpu := "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0)"

	if strings.Contains(osChoice, "Ubuntu") {
		plat = "linux"
		gpu = "Mesa Intel(R) UHD Graphics 630 (CFL GT2)"
	} else if strings.Contains(osChoice, "macOS") {
		plat = "darwin"
		gpu = "Apple M2 Pro GPU"
	}

	profile := DeviceProfile{
		DeviceID:   fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32]),
		Hostname:   fmt.Sprintf("PC-%s", strings.ToUpper(h[:6])),
		OS:         osChoice,
		Platform:   plat,
		CPUCores:   cores[hb%len(cores)],
		MemoryMB:   mems[hb%len(mems)],
		MACAddr:    fmt.Sprintf("%s:%02x:%02x:%02x", ouis[hb%len(ouis)], rawIDBytes[1], rawIDBytes[2], rawIDBytes[3]),
		Resolution: resolutions[hb%len(resolutions)],
		GPUDesc:    gpu,
		AppVer:     "1.4.2",
	}

	sm.Devices[stateKey] = profile
	return profile
}

func newDirectIPv4HTTPClient(timeout time.Duration, jar http.CookieJar, stopRedirect bool) *http.Client {
	transport := &http.Transport{
		Proxy: nil,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 12 * time.Second, KeepAlive: 30 * time.Second}).DialContext(ctx, "tcp4", addr)
		},
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout:   12 * time.Second,
		ResponseHeaderTimeout: 20 * time.Second,
		IdleConnTimeout:       30 * time.Second,
		MaxIdleConns:          32,
		MaxIdleConnsPerHost:   8,
		ForceAttemptHTTP2:     false,
	}
	client := &http.Client{Timeout: timeout, Jar: jar, Transport: transport}
	if stopRedirect {
		client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		}
	}
	return client
}

func isPrivateOrReservedIP(ip net.IP) bool {
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
		return true
	}
	privateCIDRs := []string{
		"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
		"100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
		"0.0.0.0/8", "224.0.0.0/4", "240.0.0.0/4",
		"::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
	}
	for _, cidr := range privateCIDRs {
		_, n, err := net.ParseCIDR(cidr)
		if err == nil && n.Contains(ip) {
			return true
		}
	}
	return false
}

func isBlockedTargetHost(host string) bool {
	host = strings.Trim(strings.ToLower(host), "[]")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return isPrivateOrReservedIP(ip)
	}
	// Do not resolve domains here: local DNS resolution would defeat SOCKS remote-DNS behavior.
	return false
}

type MasterAuth struct {
	Email        string
	Password     string
	IdToken      string
	AccessToken  string
	RefreshToken string
	ExpiresAt    time.Time
	mu           sync.RWMutex
	lastAuthReq  time.Time
}

func (a *MasterAuth) GetAuthToken() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.AccessToken != "" {
		return a.AccessToken
	}
	return a.IdToken
}

func generatePKCE() (string, string) {
	b := make([]byte, 32)
	rand.Read(b)
	verifier := base64.RawURLEncoding.EncodeToString(b)
	h := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(h[:])
	return verifier, challenge
}

func (a *MasterAuth) Authenticate() error {
	a.mu.Lock()
	defer a.mu.Unlock()

	if time.Since(a.lastAuthReq) < 30*time.Second && a.AccessToken != "" {
		return nil
	}
	a.lastAuthReq = time.Now()

	if a.RefreshToken != "" {
		tokenData := url.Values{
			"grant_type":    {"refresh_token"},
			"client_id":     {COGNITO_CLIENT_ID},
			"refresh_token": {a.RefreshToken},
		}
		req, _ := http.NewRequest("POST", COGNITO_DOMAIN+"/oauth2/token", strings.NewReader(tokenData.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("User-Agent", "Mozilla/5.0 Wipter/1.4.2")

		client := newDirectIPv4HTTPClient(15*time.Second, nil, false)
		resp, err := client.Do(req)
		if err == nil && resp != nil {
			defer resp.Body.Close()
		}
		if err == nil && resp != nil && resp.StatusCode == 200 {
			var res struct {
				IdToken     string `json:"id_token"`
				AccessToken string `json:"access_token"`
				ExpiresIn   int    `json:"expires_in"`
			}
			json.NewDecoder(resp.Body).Decode(&res)
			if res.AccessToken != "" {
				a.IdToken = res.IdToken
				a.AccessToken = res.AccessToken
				a.ExpiresAt = time.Now().Add(time.Duration(res.ExpiresIn) * time.Second)
				return nil
			}
		}
	}

	verifier, challenge := generatePKCE()

	jar, _ := cookiejar.New(nil)
	client := newDirectIPv4HTTPClient(20*time.Second, jar, true)

	loginParams := url.Values{
		"client_id":             {COGNITO_CLIENT_ID},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"response_type":         {"code"},
		"scope":                 {AUTH_SCOPE},
		"redirect_uri":          {REDIRECT_URI},
	}
	loginURL := fmt.Sprintf("%s/login?%s", COGNITO_DOMAIN, loginParams.Encode())

	req1, _ := http.NewRequest("GET", loginURL, nil)
	req1.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0 Safari/537.36")
	resp1, err := client.Do(req1)
	if err != nil {
		return fmt.Errorf("lỗi tải auth: %w", err)
	}
	body1, _ := io.ReadAll(resp1.Body)
	resp1.Body.Close()

	csrfRegex := regexp.MustCompile(`name=["']_csrf["']\s+value=["']([^"']+)["']`)
	csrfMatches := csrfRegex.FindSubmatch(body1)
	if len(csrfMatches) < 2 {
		csrfRegexAlt := regexp.MustCompile(`value=["']([^"']+)["']\s+name=["']_csrf["']`)
		csrfMatches = csrfRegexAlt.FindSubmatch(body1)
	}
	if len(csrfMatches) < 2 {
		return fmt.Errorf("không tìm thấy mã _csrf")
	}
	csrfToken := string(csrfMatches[1])

	postData := url.Values{
		"_csrf":              {csrfToken},
		"username":           {a.Email},
		"password":           {a.Password},
		"signInSubmitButton": {"Sign in"},
	}
	req2, _ := http.NewRequest("POST", loginURL, strings.NewReader(postData.Encode()))
	req2.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req2.Header.Set("Referer", loginURL)
	req2.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0.0.0 Safari/537.36")

	resp2, err := client.Do(req2)
	if err != nil {
		return fmt.Errorf("lỗi gửi thông tin login: %w", err)
	}
	resp2.Body.Close()

	loc := resp2.Header.Get("Location")
	codeRegex := regexp.MustCompile(`[?&]code=([^&]+)`)
	codeMatches := codeRegex.FindStringSubmatch(loc)
	if len(codeMatches) < 2 {
		return fmt.Errorf("đăng nhập thất bại: sai Email hoặc Mật khẩu")
	}
	authCode := codeMatches[1]

	tokenData := url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {COGNITO_CLIENT_ID},
		"code":          {authCode},
		"redirect_uri":  {REDIRECT_URI},
		"code_verifier": {verifier},
	}
	req3, _ := http.NewRequest("POST", COGNITO_DOMAIN+"/oauth2/token", strings.NewReader(tokenData.Encode()))
	req3.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req3.Header.Set("User-Agent", "Mozilla/5.0 Wipter/1.4.2")

	clientToken := newDirectIPv4HTTPClient(15*time.Second, nil, false)
	resp3, err := clientToken.Do(req3)
	if err != nil {
		return fmt.Errorf("lỗi đổi token: %w", err)
	}
	defer resp3.Body.Close()

	var tokens struct {
		IdToken      string `json:"id_token"`
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int    `json:"expires_in"`
	}
	if err := json.NewDecoder(resp3.Body).Decode(&tokens); err != nil {
		return fmt.Errorf("lỗi parse json token: %w", err)
	}

	a.IdToken = tokens.IdToken
	a.AccessToken = tokens.AccessToken
	if tokens.RefreshToken != "" {
		a.RefreshToken = tokens.RefreshToken
	}
	a.ExpiresAt = time.Now().Add(time.Duration(tokens.ExpiresIn) * time.Second)
	return nil
}

func parseSocks5(raw string) (host string, auth *proxy.Auth, err error) {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "socks5://") && !strings.HasPrefix(raw, "socks5h://") {
		parts := strings.Split(raw, ":")
		if len(parts) == 4 {
			return fmt.Sprintf("%s:%s", parts[0], parts[1]), &proxy.Auth{User: parts[2], Password: parts[3]}, nil
		} else if len(parts) == 2 {
			return raw, nil, nil
		}
		raw = "socks5://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", nil, err
	}
	if u.User != nil {
		p, _ := u.User.Password()
		auth = &proxy.Auth{User: u.User.Username(), Password: p}
	}
	return u.Host, auth, nil
}

// ==============================================================================
// TẦNG 3: DATA PLANE - LOCAL SOCKS5 BRIDGE & RATHOLE TUNNEL PROCESS
// ==============================================================================

func (n *NodeSession) startLocalSocksBridge(ctx context.Context, localPort int, proxyHost string) (int, error) {
	n.mu.Lock()
	if n.bridgeListener != nil {
		n.bridgeListener.Close()
		n.bridgeListener = nil
	}
	n.mu.Unlock()

	listenAddr := "127.0.0.1:0"
	if localPort > 0 {
		listenAddr = fmt.Sprintf("127.0.0.1:%d", localPort)
	}
	listener, err := net.Listen("tcp4", listenAddr)
	if err != nil {
		return 0, fmt.Errorf("lỗi tạo bridge %s: %w", listenAddr, err)
	}
	actualPort := listener.Addr().(*net.TCPAddr).Port

	n.mu.Lock()
	n.bridgeListener = listener
	n.localPort = actualPort
	n.mu.Unlock()
	globalRegistry.UpdateRuntime(n.ID, atomic.LoadInt32(&n.activeConns), actualPort, n.relayIP, atomic.LoadUint64(&n.tunnelRestarts), n.FailCount)

	go func() {
		<-ctx.Done()
		listener.Close()
	}()

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			if n.connSem == nil {
				n.connSem = make(chan struct{}, maxConnPerNode)
			}
			if !tryAcquire(globalConnSem) {
				globalRegistry.Update(n.ID, proxyHost, n.Profile.Hostname, "", "[BACKPRESSURE] Global connection limit reached", 0)
				_ = conn.Close()
				continue
			}
			if !tryAcquire(n.connSem) {
				releaseSem(globalConnSem)
				globalRegistry.Update(n.ID, proxyHost, n.Profile.Hostname, "", "[BACKPRESSURE] Per-node connection limit reached", 0)
				_ = conn.Close()
				continue
			}
			atomic.AddInt32(&activeConnections, 1)
			atomic.AddInt32(&n.activeConns, 1)
			globalRegistry.UpdateRuntime(n.ID, atomic.LoadInt32(&n.activeConns), n.localPort, n.relayIP, atomic.LoadUint64(&n.tunnelRestarts), n.FailCount)
			go func(c net.Conn) {
				defer releaseSem(globalConnSem)
				defer releaseSem(n.connSem)
				defer atomic.AddInt32(&activeConnections, -1)
				defer func() {
					atomic.AddInt32(&n.activeConns, -1)
					globalRegistry.UpdateRuntime(n.ID, atomic.LoadInt32(&n.activeConns), n.localPort, n.relayIP, atomic.LoadUint64(&n.tunnelRestarts), n.FailCount)
				}()
				n.handleBridgeConnection(c, proxyHost)
			}(conn)
		}
	}()
	return actualPort, nil
}

func (n *NodeSession) handleBridgeConnection(localConn net.Conn, proxyHost string) {
	defer localConn.Close()

	buf := make([]byte, 256)
	localConn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.ReadFull(localConn, buf[:2]); err != nil || buf[0] != 5 {
		return
	}
	nmethods := int(buf[1])
	if _, err := io.ReadFull(localConn, buf[:nmethods]); err != nil {
		return
	}
	localConn.Write([]byte{5, 0})

	if _, err := io.ReadFull(localConn, buf[:4]); err != nil || buf[1] != 1 {
		return
	}

	var targetAddr string
	switch buf[3] {
	case 1:
		if _, err := io.ReadFull(localConn, buf[:4]); err != nil {
			return
		}
		ip := net.IP(buf[:4])
		var p [2]byte
		if _, err := io.ReadFull(localConn, p[:]); err != nil {
			return
		}
		port := int(p[0])<<8 | int(p[1])
		targetAddr = fmt.Sprintf("%s:%d", ip.String(), port)
	case 3:
		if _, err := io.ReadFull(localConn, buf[:1]); err != nil {
			return
		}
		dLen := int(buf[0])
		if _, err := io.ReadFull(localConn, buf[:dLen]); err != nil {
			return
		}
		domain := string(buf[:dLen])
		var p [2]byte
		if _, err := io.ReadFull(localConn, p[:]); err != nil {
			return
		}
		port := int(p[0])<<8 | int(p[1])
		targetAddr = fmt.Sprintf("%s:%d", domain, port)
	default:
		return
	}

	if blockPrivateTarget {
		targetHost, _, splitErr := net.SplitHostPort(targetAddr)
		if splitErr != nil {
			targetHost = targetAddr
		}
		if isBlockedTargetHost(targetHost) {
			globalRegistry.Update(n.ID, proxyHost, n.Profile.Hostname, "", fmt.Sprintf("[BLOCKED_TARGET] %s", targetHost), 0)
			localConn.Write([]byte{5, 2, 0, 1, 0, 0, 0, 0, 0, 0})
			return
		}
	}

	outConn, err := n.Dialer.Dial("tcp4", targetAddr)
	if err != nil {
		localConn.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer outConn.Close()

	localConn.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})

	localConn.SetDeadline(time.Time{})
	outConn.SetDeadline(time.Time{})

	var pipeWg sync.WaitGroup
	pipeWg.Add(2)

	go func() {
		defer pipeWg.Done()
		b := getDynamicBuffer()
		defer putDynamicBuffer(b)
		for {
			_ = localConn.SetReadDeadline(time.Now().Add(bridgeIdleTimeout))
			nr, rErr := localConn.Read(*b)
			if nr > 0 {
				atomic.AddUint64(&accumulatedBytes, uint64(nr))
				globalRegistry.Update(n.ID, proxyHost, n.Profile.Hostname, "", "", uint64(nr))
				_ = outConn.SetWriteDeadline(time.Now().Add(bridgeIdleTimeout))
				if _, wErr := outConn.Write((*b)[:nr]); wErr != nil {
					break
				}
			}
			if rErr != nil {
				break
			}
		}
		outConn.Close()
	}()

	go func() {
		defer pipeWg.Done()
		b := getDynamicBuffer()
		defer putDynamicBuffer(b)
		for {
			_ = outConn.SetReadDeadline(time.Now().Add(bridgeIdleTimeout))
			nr, rErr := outConn.Read(*b)
			if nr > 0 {
				atomic.AddUint64(&accumulatedBytes, uint64(nr))
				globalRegistry.Update(n.ID, proxyHost, n.Profile.Hostname, "", "", uint64(nr))
				_ = localConn.SetWriteDeadline(time.Now().Add(bridgeIdleTimeout))
				if _, wErr := localConn.Write((*b)[:nr]); wErr != nil {
					break
				}
			}
			if rErr != nil {
				break
			}
		}
		localConn.Close()
	}()

	pipeWg.Wait()
}

func (n *NodeSession) launchRatholeDataPlane(ctx context.Context, serverIP string, localPort int) {
	n.mu.Lock()
	n.relayIP = serverIP
	n.localPort = localPort
	n.mu.Unlock()
	globalRegistry.UpdateRuntime(n.ID, atomic.LoadInt32(&n.activeConns), localPort, serverIP, atomic.LoadUint64(&n.tunnelRestarts), n.FailCount)

	n.tunnelLock.Lock()
	if n.tunnelCancel != nil {
		n.tunnelCancel()
		n.tunnelCancel = nil
	}
	if n.tunnelCmd != nil && n.tunnelCmd.Process != nil {
		_ = n.tunnelCmd.Process.Kill()
		n.tunnelCmd = nil
	}
	tunnelCtx, tunnelCancel := context.WithCancel(ctx)
	n.tunnelCancel = tunnelCancel
	n.tunnelLock.Unlock()

	configContent := fmt.Sprintf(`[client]
remote_addr = "%s:%s"
default_token = "%s"

[client.services."%s"]
token = "%s"
local_addr = "127.0.0.1:%d"
`, serverIP, FRPC_SERVER_PORT, FRPC_TOKEN, n.Profile.DeviceID, FRPC_TOKEN, localPort)

	configFile := fmt.Sprintf("/tmp/wipter_rathole_%d.toml", n.ID)
	if err := os.WriteFile(configFile, []byte(configContent), 0600); err != nil {
		globalRegistry.Update(n.ID, "", n.Profile.Hostname, "TUNNEL_CONFIG_ERROR", fmt.Sprintf("[TUNNEL_CONFIG] %v", err), 0)
		return
	}

	cmdPath := "/usr/local/bin/wipter-tunnel"
	if _, err := os.Stat(cmdPath); err != nil {
		cmdPath = "wipter-tunnel"
	}

	go func() {
		defer os.Remove(configFile)
		backoff := 2 * time.Second
		for {
			select {
			case <-tunnelCtx.Done():
				return
			default:
			}

			cmd := exec.CommandContext(tunnelCtx, cmdPath, "-c", configFile)
			cmd.Stdout = io.Discard
			cmd.Stderr = io.Discard

			n.tunnelLock.Lock()
			n.tunnelCmd = cmd
			n.tunnelLock.Unlock()

			err := cmd.Run()

			n.tunnelLock.Lock()
			if n.tunnelCmd == cmd {
				n.tunnelCmd = nil
			}
			n.tunnelLock.Unlock()

			select {
			case <-tunnelCtx.Done():
				return
			default:
			}

			errText := "process exited"
			if err != nil {
				errText = err.Error()
			}
			restarts := atomic.AddUint64(&n.tunnelRestarts, 1)
			globalRegistry.UpdateRuntime(n.ID, atomic.LoadInt32(&n.activeConns), n.localPort, n.relayIP, restarts, n.FailCount)
			globalRegistry.Update(n.ID, "", n.Profile.Hostname, "TUNNEL_RESTARTING", fmt.Sprintf("[TUNNEL_EXIT] %s; restart in %s", errText, backoff), 0)

			timer := time.NewTimer(backoff)
			select {
			case <-timer.C:
			case <-tunnelCtx.Done():
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				return
			}
			if backoff < 60*time.Second {
				backoff *= 2
				if backoff > 60*time.Second {
					backoff = 60 * time.Second
				}
			}
		}
	}()
}

// BẮT TAY STOMP CHUẨN XÁC KÈM ĐẦY ĐỦ TOKEN TRONG TỪNG FRAME
func (n *NodeSession) Run(ctx context.Context, auth *MasterAuth) {
	defer func() {
		if r := recover(); r != nil {}
		n.cleanup()
	}()

	host, _, _ := parseSocks5(n.RawProxy)
	globalRegistry.Update(n.ID, host, n.Profile.Hostname, "CONNECTING", "Đang kết nối...", 0)

	for {
		select {
		case <-ctx.Done():
			return
		default:
			err := n.executeSession(ctx, auth)
			n.cleanup()

			if err != nil {
				n.mu.Lock()
				n.FailCount++
				fc := n.FailCount
				n.mu.Unlock()
				globalRegistry.UpdateRuntime(n.ID, atomic.LoadInt32(&n.activeConns), n.localPort, n.relayIP, atomic.LoadUint64(&n.tunnelRestarts), fc)

				var sleepSec time.Duration
				errStr := err.Error()

				if strings.Contains(errStr, "401") || strings.Contains(errStr, "unauthorized") {
					go auth.Authenticate()
					globalRegistry.Update(n.ID, host, n.Profile.Hostname, "AUTH_RETRY", "Token hết hạn, đang làm mới...", 0)
					sleepSec = 10 * time.Second
				} else if fc >= 3 {
					atomic.AddInt32(&isolatedDeadNode, 1)
					globalRegistry.Update(n.ID, host, n.Profile.Hostname, "DEAD_QUARANTINE", fmt.Sprintf("[PROXY_DEAD] %s", errStr), 0)
					sleepSec = 5 * time.Minute
				} else {
					globalRegistry.Update(n.ID, host, n.Profile.Hostname, "RETRYING", fmt.Sprintf("[LỖI #%d] %s", fc, errStr), 0)
					sleepSec = time.Duration(8+mathRand.Intn(12)) * time.Second
				}

				select {
				case <-time.After(sleepSec):
					if fc >= 3 {
						atomic.AddInt32(&isolatedDeadNode, -1)
					}
				case <-ctx.Done():
					return
				}
			}
		}
	}
}

func (n *NodeSession) executeSession(ctx context.Context, auth *MasterAuth) error {
	host, proxyAuth, err := parseSocks5(n.RawProxy)
	if err != nil {
		return fmt.Errorf("proxy parse failed: %w", err)
	}

	dialer, err := proxy.SOCKS5("tcp4", host, proxyAuth, &net.Dialer{
		Timeout:   12 * time.Second,
		KeepAlive: 30 * time.Second,
	})
	if err != nil {
		return err
	}
	n.Dialer = dialer

	token := auth.GetAuthToken()
	if token == "" {
		return fmt.Errorf("token empty")
	}

	wsDialer := websocket.Dialer{
		NetDial: func(network, addr string) (net.Conn, error) {
			return dialer.Dial("tcp4", addr)
		},
		TLSClientConfig:  &tls.Config{MinVersion: tls.VersionTLS12, ServerName: "ch.wipter.com"},
		HandshakeTimeout: 15 * time.Second,
	}

	headers := http.Header{}
	headers.Add("User-Agent", fmt.Sprintf("Mozilla/5.0 (%s) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36 Wipter/%s", n.Profile.OS, n.Profile.AppVer))

	rawConn, resp, err := wsDialer.DialContext(ctx, WIPTER_STOMP_URL, headers)
	if err != nil {
		if resp != nil && resp.StatusCode == 401 {
			return fmt.Errorf("401 unauthorized")
		}
		return err
	}
	if resp != nil && resp.Body != nil {
		resp.Body.Close()
	}

	safeWS := &SafeWSConn{conn: rawConn}

	n.mu.Lock()
	n.SafeWS = safeWS
	n.IsOnline = true
	n.FailCount = 0
	n.mu.Unlock()

	// 1. GỬI KHUNG CONNECT KÈM ĐẦY ĐỦ deviceId, newSessionId VÀ token
	stompConnect := fmt.Sprintf("CONNECT\naccept-version:1.1,1.2\nhost:ch.wipter.com\nheart-beat:10000,10000\ndeviceId:%s\nnewSessionId:%s\ntoken:%s\n\n\x00",
		n.Profile.DeviceID, n.Profile.DeviceID, token)
	if err := safeWS.WriteMessage(websocket.TextMessage, []byte(stompConnect)); err != nil {
		return err
	}

	// Đọc phản hồi CONNECTED từ Server Wipter
	rawConn.SetReadDeadline(time.Now().Add(15 * time.Second))
	_, respMsg, err := rawConn.ReadMessage()
	if err != nil {
		return fmt.Errorf("stomp handshake error: %w", err)
	}

	respStr := strings.ReplaceAll(string(respMsg), "\x00", "")
	if !strings.HasPrefix(respStr, "CONNECTED") && !strings.HasPrefix(respStr, "ERROR") {
		return fmt.Errorf("unexpected STOMP handshake response: %s", strings.TrimSpace(respStr))
	}
	if strings.HasPrefix(respStr, "ERROR") {
		lines := strings.Split(respStr, "\n")
		errMsg := "auth failed"
		for _, l := range lines {
			if strings.HasPrefix(l, "message:") {
				errMsg = strings.TrimPrefix(l, "message:")
				break
			}
		}
		return fmt.Errorf("stomp: %s", strings.TrimSpace(errMsg))
	}

	// 2. SUBSCRIBE 7 KÊNH CHUẨN XÁC VỚI HEADER token ĐÍNH KÈM
	subs := []string{
		fmt.Sprintf("SUBSCRIBE\nid:sub-0\ndestination:/topic/session-options\ntoken:%s\n\n\x00", token),
		fmt.Sprintf("SUBSCRIBE\nid:sub-1\ndestination:/topic/registration/%s\ntoken:%s\n\n\x00", n.Profile.DeviceID, token),
		fmt.Sprintf("SUBSCRIBE\nid:sub-2\ndestination:/topic/proxy-request/%s\ntoken:%s\n\n\x00", n.Profile.DeviceID, token),
		fmt.Sprintf("SUBSCRIBE\nid:sub-3\ndestination:/topic/tunnel-request/%s\ntoken:%s\n\n\x00", n.Profile.DeviceID, token),
		fmt.Sprintf("SUBSCRIBE\nid:sub-4\ndestination:/topic/location/%s\ntoken:%s\n\n\x00", n.Profile.DeviceID, token),
		fmt.Sprintf("SUBSCRIBE\nid:sub-5\ndestination:/topic/desktop-stats/%s\ntoken:%s\n\n\x00", n.Profile.DeviceID, token),
		fmt.Sprintf("SUBSCRIBE\nid:sub-6\ndestination:/topic/device-performance-snapshot/%s\ntoken:%s\n\n\x00", n.Profile.DeviceID, token),
	}
	for _, sub := range subs {
		if err := safeWS.WriteMessage(websocket.TextMessage, []byte(sub)); err != nil {
			return err
		}
	}

	// 3. GỬI BẢN TIN ĐĂNG KÝ VỚI HEADER token VÀ content-type: application/json
	platformName := "Windows"
	if strings.Contains(strings.ToLower(n.Profile.OS), "ubuntu") || strings.Contains(strings.ToLower(n.Profile.OS), "linux") {
		platformName = "Linux"
	}

	regPayload, _ := json.Marshal(map[string]interface{}{
		"deviceId":        n.Profile.DeviceID,
		"devicePlatform":  platformName,
		"platformVersion": n.Profile.OS,
		"deviceType":      "DESKTOP",
		"hostname":        n.Profile.Hostname,
		"appVersion":      n.Profile.AppVer,
		"cpuCores":        n.Profile.CPUCores,
		"lastUpdatedAt":   time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		"totalRAM":        n.Profile.MemoryMB,
		"availableRAM":    n.Profile.MemoryMB / 2,
		"connectionType":  "ETHERNET",
		"port25Enabled":   false,
		"socksEnabled":    true,
		"cpuArch":         "x64",
		"fingerprint":     strings.ReplaceAll(n.Profile.DeviceID, "-", ""),
		"cpuUsage":        0.05,
	})

	sendReg := fmt.Sprintf("SEND\ndestination:/app/topic/registration\ncontent-type:application/json\ntoken:%s\n\n%s\x00", token, string(regPayload))
	if err := safeWS.WriteMessage(websocket.TextMessage, []byte(sendReg)); err != nil {
		return err
	}

	registeredOnline := false
	globalRegistry.Update(n.ID, host, n.Profile.Hostname, "REG_PENDING", "[PENDING] Đang chờ cấp phép...", 0)
	defer func() {
		if registeredOnline {
			atomic.AddInt32(&onlineNodesCount, -1)
		}
	}()

	// Luồng STOMP Heartbeat ngẫu nhiên
	go func() {
		ticker := time.NewTicker(time.Duration(10+mathRand.Intn(5)) * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				if err := safeWS.WriteMessage(websocket.TextMessage, []byte("\n")); err != nil {
					return
				}
			case <-ctx.Done():
				return
			}
		}
	}()

	// Đọc và xử lý phản hồi từ Server
	for {
		rawConn.SetReadDeadline(time.Now().Add(75 * time.Second))
		_, msg, err := rawConn.ReadMessage()
		if err != nil {
			return err
		}

		rawFrames := strings.Split(string(msg), "\x00")
		for _, frame := range rawFrames {
			frame = strings.TrimSpace(frame)
			if frame == "" {
				continue
			}

			if strings.HasPrefix(frame, "MESSAGE") {
				parts := strings.SplitN(frame, "\n\n", 2)
				if len(parts) >= 2 {
					headersPart := parts[0]
					bodyPart := strings.TrimRight(parts[1], "\x00")

					// BẮT GÓI TIN MÁY CHỦ DUYỆT THIẾT BỊ VÀ TRẢ VỀ publicIP (RELAY SERVER)
					if strings.Contains(headersPart, "/topic/registration/") {
						var regRes struct {
							PublicIP           string `json:"publicIP"`
							RegistrationStatus string `json:"registration_status"`
							Reason             string `json:"reason"`
						}
						if err := json.Unmarshal([]byte(bodyPart), &regRes); err == nil {
							if regRes.RegistrationStatus == "FAILED" {
								errMsg := regRes.Reason
								if errMsg == "" {
									errMsg = "REGISTRATION_FAILED"
								}
								globalRegistry.Update(n.ID, host, n.Profile.Hostname, "REG_REJECTED", fmt.Sprintf("[REJECTED] %s", errMsg), 0)
							} else if regRes.PublicIP != "" {
								localBridgePort, err := n.startLocalSocksBridge(ctx, 0, host)
								if err != nil {
									return fmt.Errorf("local bridge failed: %w", err)
								}
								n.launchRatholeDataPlane(ctx, regRes.PublicIP, localBridgePort)
								if !registeredOnline {
									atomic.AddInt32(&onlineNodesCount, 1)
									registeredOnline = true
								}

								note := fmt.Sprintf("[ACTIVE] Relay: %s (Tunnel OK)", regRes.PublicIP)
								globalRegistry.Update(n.ID, host, n.Profile.Hostname, "ONLINE", note, 0)
							}
						}
					} else if strings.Contains(headersPart, "/topic/session-options") && !registeredOnline {
						globalRegistry.Update(n.ID, host, n.Profile.Hostname, "REG_PENDING", "[SESSION_ACTIVE] Đang chờ đăng ký thiết bị", 0)
					}
				}
			}
		}
	}
}

func (n *NodeSession) cleanup() {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.SafeWS != nil {
		n.SafeWS.Close()
		n.SafeWS = nil
	}
	n.tunnelLock.Lock()
	if n.tunnelCancel != nil {
		n.tunnelCancel()
		n.tunnelCancel = nil
	}
	if n.tunnelCmd != nil && n.tunnelCmd.Process != nil {
		_ = n.tunnelCmd.Process.Kill()
		n.tunnelCmd = nil
	}
	n.tunnelLock.Unlock()
	if n.bridgeListener != nil {
		n.bridgeListener.Close()
		n.bridgeListener = nil
	}
	n.localPort = 0
	n.relayIP = ""
	n.IsOnline = false
	globalRegistry.UpdateRuntime(n.ID, atomic.LoadInt32(&n.activeConns), 0, "", atomic.LoadUint64(&n.tunnelRestarts), n.FailCount)
}

func startDiagnosticServer() {
	diagnosticAddr := strings.TrimSpace(os.Getenv("WIPTER_DIAGNOSTIC_ADDR"))
	if diagnosticAddr == "" {
		diagnosticAddr = DIAGNOSTIC_ADDR_DEFAULT
	}

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("ok"))
	})

	http.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		globalRegistry.mu.RLock()
		defer globalRegistry.mu.RUnlock()

		list := make([]*NodeDiagnosticInfo, 0, len(globalRegistry.nodes))
		for i := 1; i <= len(globalRegistry.nodes); i++ {
			if n, ok := globalRegistry.nodes[i]; ok {
				list = append(list, n)
			}
		}

		zoneName := "GREEN (MAX_PERFORMANCE)"
		switch atomic.LoadInt32(&currentPressureZone) {
		case ZONE_YELLOW:
			zoneName = "YELLOW (BALANCED)"
		case ZONE_ORANGE:
			zoneName = "ORANGE (CONSERVATIVE)"
		case ZONE_RED:
			zoneName = "RED (EMERGENCY_RECLAIM)"
		}

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"total":         atomic.LoadInt32(&totalNodesLoaded),
			"online":        atomic.LoadInt32(&onlineNodesCount),
			"dead_isolated": atomic.LoadInt32(&isolatedDeadNode),
			"total_bytes":   atomic.LoadUint64(&accumulatedBytes),
			"active_connections": atomic.LoadInt32(&activeConnections),
			"max_conn_global": maxConnGlobal,
			"max_conn_per_node": maxConnPerNode,
			"block_private_targets": blockPrivateTarget,
			"host_total_mb": atomic.LoadInt64(&totalHostRAM_MB),
			"host_avail_mb": atomic.LoadInt64(&availHostRAM_MB),
			"pressure_zone": zoneName,
			"nodes":         list,
		})
	})

	go func() {
		server := &http.Server{
			Addr:         diagnosticAddr,
			ReadTimeout:  5 * time.Second,
			WriteTimeout: 5 * time.Second,
		}
		server.ListenAndServe()
	}()
}

func main() {
	email := os.Getenv("WIPTER_EMAIL")
	password := os.Getenv("WIPTER_PASSWORD")

	if email == "" || password == "" {
		log.Fatal("[FATAL] Chưa cấu hình WIPTER_EMAIL hoặc WIPTER_PASSWORD trong config.env")
	}

	maxConnPerNode = getEnvInt("WIPTER_MAX_CONN_PER_NODE", maxConnPerNode)
	maxConnGlobal = getEnvInt("WIPTER_MAX_CONN_GLOBAL", maxConnGlobal)
	bridgeIdleTimeout = time.Duration(getEnvInt("WIPTER_IDLE_TIMEOUT_SEC", int(bridgeIdleTimeout/time.Second))) * time.Second
	blockPrivateTarget = getEnvBool("WIPTER_BLOCK_PRIVATE_TARGETS", blockPrivateTarget)
	globalConnSem = make(chan struct{}, maxConnGlobal)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go startDynamicResourceGovernor(ctx)
	startDiagnosticServer()

	stateMgr := LoadStateManager()
	authMgr := &MasterAuth{Email: email, Password: password}

	log.Println("[INFO] Đang xác thực OAuth2 PKCE với máy chủ Wipter...")
	if err := authMgr.Authenticate(); err != nil {
		log.Fatalf("[FATAL] Đăng nhập thất bại: %v", err)
	}
	log.Println("[OK] Đăng nhập thành công! Token AWS Cognito đã sẵn sàng.")

	go func() {
		ticker := time.NewTicker(12 * time.Hour)
		defer ticker.Stop()
		for range ticker.C {
			authMgr.Authenticate()
		}
	}()

	data, err := os.ReadFile("proxies.txt")
	if err != nil {
		log.Fatalf("[FATAL] Không thể đọc proxies.txt: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	seenProxies := make(map[string]bool)
	var validProxies []string

	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l != "" && !strings.HasPrefix(l, "#") && !seenProxies[l] {
			seenProxies[l] = true
			validProxies = append(validProxies, l)
		}
	}

	atomic.StoreInt32(&totalNodesLoaded, int32(len(validProxies)))

	log.Printf("==================================================================")
	log.Printf(" WIPTER REAL-TIME ELASTIC HUB (FULL STOMP + RATHOLE DATA PLANE)   ")
	log.Printf(" Tổng số Proxies nạp vào: %d (Đã khử trùng lặp)                   ", len(validProxies))
	log.Printf("==================================================================")

	for i, proxyLine := range validProxies {
		profile := stateMgr.GetOrGenerate(proxyLine, i+1)
		nodeCtx, nodeCancel := context.WithCancel(ctx)

		session := &NodeSession{
			ID:       i + 1,
			RawProxy: proxyLine,
			Profile:  profile,
			cancel:   nodeCancel,
		}
		go session.Run(nodeCtx, authMgr)
		time.Sleep(30 * time.Millisecond)
	}
	stateMgr.Save()

	go func() {
		ticker := time.NewTicker(300 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				mBytes := float64(atomic.LoadUint64(&accumulatedBytes)) / (1024 * 1024)
				log.Printf("[24/7 MONITOR] Total: %d | ONLINE: %d | DEAD_ISOLATED: %d | TRAFFIC: %.2f MB | Host Avail RAM: %dMB",
					atomic.LoadInt32(&totalNodesLoaded),
					atomic.LoadInt32(&onlineNodesCount),
					atomic.LoadInt32(&isolatedDeadNode),
					mBytes,
					atomic.LoadInt64(&availHostRAM_MB))
			case <-ctx.Done():
				return
			}
		}
	}()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan

	log.Println("[INFO] Đang lưu cấu hình trạng thái và dừng an toàn...")
	stateMgr.Save()
	cancel()
	time.Sleep(2 * time.Second)
	log.Println("[OK] Đã dừng toàn bộ Wipter Engine an toàn.")
}