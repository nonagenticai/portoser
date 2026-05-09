import axios from 'axios'
import { tokenStore } from '../auth/tokenStore'
import * as authApi from '../auth/authApi'

const api = axios.create({
  baseURL: '/api',
  headers: {
    'Content-Type': 'application/json',
  },
})

// Attach the access token (if any) to every outgoing request. We don't gate
// this on `auth_enabled` because in dev (auth disabled) sessionStorage is
// empty, so there's just no header — backend lets it through.
api.interceptors.request.use((config) => {
  const token = tokenStore.getAccessToken()
  if (token) {
    config.headers = config.headers || {}
    config.headers.Authorization = `Bearer ${token}`
  }
  return config
})

// Track in-flight refresh so multiple parallel 401s don't trigger a stampede
// of refresh calls. Each retry awaits the same promise.
let inflightRefresh = null

async function refreshOnce() {
  if (!inflightRefresh) {
    const rt = tokenStore.getRefreshToken()
    if (!rt) {
      return null
    }
    inflightRefresh = authApi
      .refresh(rt)
      .then((res) => {
        tokenStore.setTokens({
          accessToken: res.access_token,
          refreshToken: res.refresh_token,
          expiresIn: res.expires_in,
        })
        return res.access_token
      })
      .catch(() => {
        tokenStore.clear()
        return null
      })
      .finally(() => {
        // Reset the slot AFTER the promise settles.
        const settled = inflightRefresh
        inflightRefresh = null
        return settled
      })
  }
  return inflightRefresh
}

// Response interceptor: structured errors + one-shot retry on 401.
api.interceptors.response.use(
  (response) => response,
  async (error) => {
    const originalRequest = error.config
    if (
      error.response?.status === 401 &&
      originalRequest &&
      !originalRequest._retried &&
      !originalRequest.url?.startsWith('/auth/')  // never retry the auth flow itself
    ) {
      originalRequest._retried = true
      const newToken = await refreshOnce()
      if (newToken) {
        originalRequest.headers = originalRequest.headers || {}
        originalRequest.headers.Authorization = `Bearer ${newToken}`
        return api.request(originalRequest)
      }
      // Refresh failed: tokens already cleared. Let the AuthProvider observe
      // sessionStorage on its next render — the 401 propagates so callers
      // can show the right error.
    }

    if (error.response) {
      const structured = {
        status: error.response.status,
        message: error.response.data?.message || error.message,
        url: error.config?.url,
        isNetworkError: false,
        data: error.response.data,
      }
      console.warn(`API Error ${structured.status}:`, structured)
      return Promise.reject(structured)
    } else if (error.request) {
      return Promise.reject({
        status: 0,
        message: 'Network error - server unreachable',
        isNetworkError: true,
        url: error.config?.url,
      })
    }
    return Promise.reject(error)
  }
)

/**
 * Build a WebSocket URL with the access token in the query string.
 *
 * Browser WebSocket API doesn't allow custom headers, so the canonical way
 * to authenticate a WS upgrade in a SPA is to embed the token. The backend
 * `auth.websocket.authenticate_websocket` reads it from `?token=`.
 */
export function buildAuthedWsUrl(path) {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  const base = `${protocol}//${window.location.host}${path}`
  const token = tokenStore.getAccessToken()
  if (!token) return base
  const sep = base.includes('?') ? '&' : '?'
  return `${base}${sep}token=${encodeURIComponent(token)}`
}

// Machine API
// Backend returns { machines: [...] } but consumers want a plain array.
// Unwrap here so every call site can rely on Array.isArray(result).
export const fetchMachines = async () => {
  const { data } = await api.get('/machines')
  if (Array.isArray(data)) return data
  return Array.isArray(data?.machines) ? data.machines : []
}

export const createMachine = async (machine) => {
  const { data } = await api.post('/machines', machine)
  return data
}

export const updateMachine = async ({ name, ...update }) => {
  const { data } = await api.put(`/machines/${name}`, update)
  return data
}

export const deleteMachine = async (name) => {
  const { data } = await api.delete(`/machines/${name}`)
  return data
}

export const getMachineDetails = async (name) => {
  const { data } = await api.get(`/machines/${name}`)
  return data
}

// Machine control operations
export const startMachine = async (name) => {
  const { data } = await api.post(`/machines/${name}/start`)
  return data
}

export const stopMachine = async (name) => {
  const { data } = await api.post(`/machines/${name}/stop`)
  return data
}

export const restartMachine = async (name) => {
  const { data } = await api.post(`/machines/${name}/restart`)
  return data
}

// Service API
// Same array-unwrap as fetchMachines.
export const fetchServices = async () => {
  const { data } = await api.get('/services')
  if (Array.isArray(data)) return data
  return Array.isArray(data?.services) ? data.services : []
}

export const createService = async (service) => {
  const { data } = await api.post('/services', service)
  return data
}

export const updateService = async ({ name, ...update }) => {
  const { data } = await api.put(`/services/${name}`, update)
  return data
}

export const deleteService = async (name) => {
  const { data } = await api.delete(`/services/${name}`)
  return data
}

export const getServiceDetails = async (name) => {
  const { data } = await api.get(`/services/${name}`)
  return data
}

export const getServiceHealth = async (name) => {
  const { data } = await api.get(`/services/${name}/health`)
  return data
}

export const startService = async (name) => {
  const { data } = await api.post(`/services/${name}/start`)
  return data
}

export const stopService = async (name, force = false) => {
  const { data } = await api.post(`/services/${name}/stop`, null, {
    params: { force }
  })
  return data
}

export const restartService = async (name) => {
  const { data } = await api.post(`/services/${name}/restart`)
  return data
}

export const rebuildService = async (name) => {
  const { data } = await api.post(`/services/${name}/rebuild`)
  return data
}

// Deployment API
export const createDeploymentPlan = async (plan) => {
  const { data } = await api.post('/deployment/plan', plan)
  return data
}

export const executeDeployment = async (plan) => {
  const { data } = await api.post('/deployment/execute', plan)
  return data
}

// Status API
export const getClusterStatus = async () => {
  const { data } = await api.get('/status')
  return data
}

export const healthCheck = async () => {
  const { data } = await api.get('/health')
  return data
}

// Diagnostics API
export const runDiagnostics = async (serviceName, machineName) => {
  const { data } = await api.post('/diagnostics/run', {
    service: serviceName,
    machine: machineName
  })
  return data
}

export const getDiagnosticResults = async (serviceName, machineName) => {
  const { data } = await api.get(`/diagnostics/${serviceName}/${machineName}`)
  return data
}

export const applyFix = async (solutionId, serviceName, machineName) => {
  const { data } = await api.post('/diagnostics/apply-fix', {
    solution_id: solutionId,
    service: serviceName,
    machine: machineName
  })
  return data
}

export const getServiceHealthCheck = async (serviceName, machineName) => {
  const { data } = await api.get(`/diagnostics/health/${serviceName}/${machineName}`)
  return data
}

export const getAllHealthChecks = async () => {
  const { data } = await api.get('/diagnostics/health/all')
  return data
}

export const getProblemFrequency = async () => {
  const { data } = await api.get('/diagnostics/problems/frequency')
  return data
}

export const getDiagnosticHistory = async (serviceName, machineName, limit = 50) => {
  const { data } = await api.get(`/diagnostics/history/${serviceName}/${machineName}`, {
    params: { limit }
  })
  return data
}

// Knowledge Base API
export const getPlaybooks = async (category = null, tag = null) => {
  const { data } = await api.get('/knowledge/playbooks', {
    params: { category, tag }
  })
  return data
}

export const getPlaybook = async (playbookName) => {
  const { data } = await api.get(`/knowledge/playbooks/${playbookName}`)
  return data
}

export const getServiceInsights = async (serviceName) => {
  const { data } = await api.get(`/knowledge/insights/${serviceName}`)
  return data
}

export const getKnowledgeStats = async () => {
  const { data } = await api.get('/knowledge/stats')
  return data
}

// Health API
export const getHealthDashboard = async (refresh = true) => {
  const { data } = await api.get('/health/dashboard', {
    params: { refresh }
  })
  return data
}

export const getHealthTimeline = async (hours = 24) => {
  const { data } = await api.get('/health/timeline', {
    params: { hours }
  })
  return data
}

export const getHealthHeatmap = async (days = 30) => {
  const { data } = await api.get('/health/heatmap', {
    params: { days }
  })
  return data
}

// Intelligent Deployment API
export const intelligentDeploy = async (service, machine, options = {}) => {
  const { data } = await api.post('/deployment/intelligent-execute', {
    service,
    machine,
    auto_heal: options.autoHeal || false,
    dry_run: options.dryRun || false
  })
  return data
}

export const getDeploymentPhases = async (deploymentId) => {
  const { data } = await api.get(`/deployment/${deploymentId}/phases`)
  return data
}

export const dryRunDeployment = async (service, machine) => {
  const { data } = await api.post('/deployment/dry-run', {
    service,
    machine
  })
  return data
}

export const getDeploymentResult = async (deploymentId) => {
  const { data } = await api.get(`/deployment/${deploymentId}`)
  return data
}

// ============================================================================
// MCP (Model Context Protocol) API
// ============================================================================

export const getMCPStatus = async () => {
  const { data } = await api.get('/mcp/status')
  return data
}

export const getMCPConfig = async () => {
  const { data } = await api.get('/mcp/config')
  return data
}

export const getMCPTools = async () => {
  const { data } = await api.get('/mcp/tools')
  return data
}

export const getMCPTool = async (toolName) => {
  const { data } = await api.get(`/mcp/tools/${toolName}`)
  return data
}

export const createMCPTool = async (toolData) => {
  const { data } = await api.post('/mcp/tools', toolData)
  return data
}

export const updateMCPTool = async (toolName, toolData) => {
  const { data } = await api.put(`/mcp/tools/${toolName}`, toolData)
  return data
}

export const deleteMCPTool = async (toolName) => {
  const { data } = await api.delete(`/mcp/tools/${toolName}`)
  return data
}

export const getMCPAuditLogs = async (params = {}) => {
  const { data } = await api.get('/mcp/audit/logs', { params })
  return data
}

// ============================================================================
// Metrics API
// ============================================================================

export const getServiceMetrics = async (serviceName, machineName, timeRange = '1h') => {
  try {
    const { data } = await api.get(`/metrics/${serviceName}/${machineName}`, {
      params: { timeRange }
    })
    return data || null
  } catch (error) {
    // Return null for 404s (metrics not available for this service/machine combo)
    if (error.status === 404) {
      console.debug(`Metrics not available for ${serviceName}/${machineName}`)
      return null
    }
    console.warn(`Failed to fetch metrics for ${serviceName}/${machineName}:`, error.message)
    throw error
  }
}

export const getAllMetrics = async () => {
  try {
    const { data } = await api.get('/metrics/all')
    return data || []
  } catch (error) {
    // Return empty array for 404s (no metrics available)
    if (error.status === 404) {
      console.debug('No metrics available yet')
      return []
    }
    console.warn('Failed to fetch all metrics:', error.message)
    throw error
  }
}

export const getMetricsHistory = async (serviceName, machineName, startTime, endTime) => {
  const { data } = await api.get(`/metrics/${serviceName}/${machineName}/history`, {
    params: { startTime, endTime }
  })
  return data
}

// ============================================================================
// Uptime API
// ============================================================================

export const getServiceUptime = async (serviceName, machineName, timeRange = '7d') => {
  const { data } = await api.get(`/uptime/${serviceName}/${machineName}`, {
    params: { timeRange }
  })
  return data
}

export const getUptimeEvents = async (serviceName, machineName, params = {}) => {
  const { data } = await api.get(`/uptime/${serviceName}/${machineName}/events`, {
    params
  })
  return data
}

export const getAllUptime = async () => {
  const { data } = await api.get('/uptime/all')
  return data
}

// ============================================================================
// Certificates API
// ============================================================================

export const listCertificates = async () => {
  const { data } = await api.get('/certificates/list')
  return data
}

export const checkBrowserCerts = async (service = null) => {
  const { data } = await api.get('/certificates/browser-status', {
    params: { service }
  })
  return data
}

export const installBrowserCerts = async (service = null) => {
  const { data } = await api.post('/certificates/browser/install', null, {
    params: { service }
  })
  return data
}

export const uninstallBrowserCerts = async (service = null) => {
  const { data } = await api.delete('/certificates/browser/uninstall', {
    params: { service }
  })
  return data
}

export const copyKeycloakCA = async (service) => {
  const { data } = await api.post(`/certificates/keycloak-ca/copy/${service}`)
  return data
}

export const copyKeycloakCAAll = async () => {
  const { data } = await api.post('/certificates/keycloak-ca/copy-all')
  return data
}

export const validateServiceCerts = async (service) => {
  const { data } = await api.get(`/certificates/validate/${service}`)
  return data
}

export const generateCertificates = async (service) => {
  const { data } = await api.post(`/certificates/generate/${service}`)
  return data
}

export const generateServerCertificates = async (service) => {
  const { data } = await api.post(`/certificates/generate-server/${service}`)
  return data
}

export const deployCertificates = async (service, machine) => {
  const { data } = await api.post(`/certificates/deploy/${service}/${machine}`)
  return data
}

export default api
