// Tiny Go HTTP file server — demo service for the portoser fleet.
//
// Serves an in-memory list of "shared files" (no disk I/O so the container
// stays trivially small) plus the standard /health and /metrics endpoints
// every fleet service exposes. Picked Go for its third-of-three coverage:
// node-recipes is Express, python-sensors is FastAPI, this is net/http.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

type file struct {
	Name      string `json:"name"`
	SizeBytes int64  `json:"size_bytes"`
	SHA256    string `json:"sha256"`
}

var (
	startedAt = time.Now()
	requests  atomic.Int64

	files = []file{
		{"linux-mint-22.iso", 2_968_059_904, "3f7b...c91d"},
		{"family-photos-2025.tar.zst", 18_402_193_408, "c2a4...8801"},
		{"backups/postgres-20260203.sql.gz", 1_028_193, "b03e...ff20"},
		{"firmware/openwrt-23.05.bin", 9_437_184, "ab12...cd34"},
	}
)

func index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!doctype html><title>go-fileserver</title>
<h1>go-fileserver</h1>
<p>Tiny Go net/http service. Demo for the portoser fleet.</p>
<ul>`)
	for _, f := range files {
		fmt.Fprintf(w, "<li><code>%s</code> — %d bytes</li>", f.Name, f.SizeBytes)
	}
	fmt.Fprint(w, `</ul>
<p><a href="/api/files">/api/files</a> · <a href="/health">/health</a> · <a href="/metrics">/metrics</a></p>`)
}

func apiFiles(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(files)
}

func health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"status":"ok","uptime_s":%d}`, int(time.Since(startedAt).Seconds()))
}

func metrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w,
		"# HELP go_fileserver_requests_total Requests served\n"+
			"# TYPE go_fileserver_requests_total counter\n"+
			"go_fileserver_requests_total %d\n"+
			"# HELP go_fileserver_uptime_seconds Process uptime\n"+
			"# TYPE go_fileserver_uptime_seconds gauge\n"+
			"go_fileserver_uptime_seconds %d\n"+
			"# HELP go_fileserver_files Files exposed\n"+
			"# TYPE go_fileserver_files gauge\n"+
			"go_fileserver_files %d\n",
		requests.Load(),
		int(time.Since(startedAt).Seconds()),
		len(files),
	)
}

func count(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		h(w, r)
	}
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "9000"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", count(index))
	mux.HandleFunc("/api/files", count(apiFiles))
	mux.HandleFunc("/health", count(health))
	mux.HandleFunc("/metrics", count(metrics))

	addr := ":" + port
	log.Printf("go-fileserver listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
