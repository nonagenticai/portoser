import { useState, useEffect, useCallback } from 'react'
import { useWebSocket } from './useWebSocket.js'
import { useServiceDiscovery } from './useServiceDiscovery.js'
import { buildAuthedWsUrl, getAllMetrics, getServiceMetrics } from '../api/client.js'

/**
 * Custom hook for fetching and subscribing to service metrics
 * Provides real-time metrics updates via WebSocket
 * Uses service discovery to avoid fetching metrics for invalid service/machine combinations
 *
 * @param {string} serviceName - Name of the service
 * @param {string} machineName - Name of the machine hosting the service
 * @param {object} options - Configuration options
 * @param {string} options.timeRange - Time range for historical data (1h, 6h, 24h, 7d, 30d)
 * @param {boolean} options.realTime - Enable real-time WebSocket updates
 * @param {number} options.refreshInterval - Auto-refresh interval in ms (default: 10000)
 * @returns {object} - { metrics, loading, error, refetch }
 */
export function useMetrics(serviceName, machineName, options = {}) {
  const {
    timeRange = '1h',
    realTime = true,
    refreshInterval = 10000
  } = options

  const [metrics, setMetrics] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  // Build authenticated WebSocket URL (token attached as ?token= query param;
  // backend reads it via auth.websocket.authenticate_websocket).
  const wsUrl = typeof window !== 'undefined' ? buildAuthedWsUrl('/ws') : null

  // WebSocket connection for real-time updates
  const { lastMessage } = useWebSocket(wsUrl)

  // Service discovery to check if service runs on machine
  const { serviceRunsOnMachine, loading: discoveryLoading } = useServiceDiscovery()

  // Fetch metrics from API
  const fetchMetrics = useCallback(async () => {
    if (!serviceName || !machineName) return

    // Check if service runs on this machine before fetching
    if (!discoveryLoading && !serviceRunsOnMachine(serviceName, machineName)) {
      console.debug(`Skipping metrics fetch: ${serviceName} does not run on ${machineName}`)
      setMetrics(null)
      setLoading(false)
      return
    }

    try {
      setLoading(true)
      setError(null)

      // Authenticated client — raw fetch would bypass the Bearer interceptor
      // and 401 on every poll when KEYCLOAK_ENABLED=true.
      const data = await getServiceMetrics(serviceName, machineName, timeRange)
      setMetrics(data)
    } catch (err) {
      console.error('Error fetching metrics:', err)
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }, [serviceName, machineName, timeRange, discoveryLoading, serviceRunsOnMachine])

  // Initial fetch
  useEffect(() => {
    fetchMetrics()
  }, [fetchMetrics])

  // Auto-refresh interval
  useEffect(() => {
    if (!realTime || !refreshInterval) return

    const interval = setInterval(() => {
      fetchMetrics()
    }, refreshInterval)

    return () => clearInterval(interval)
  }, [realTime, refreshInterval, fetchMetrics])

  // Handle WebSocket messages for real-time updates
  useEffect(() => {
    if (!lastMessage || !realTime) return

    try {
      const data = JSON.parse(lastMessage.data)

      // Update metrics if message is for this service
      if (
        data.type === 'metrics_update' &&
        data.service === serviceName &&
        data.machine === machineName
      ) {
        setMetrics(prevMetrics => ({
          ...prevMetrics,
          current: data.metrics,
          lastUpdated: new Date().toISOString()
        }))
      }
    } catch (err) {
      console.error('Error processing WebSocket message:', err)
    }
  }, [lastMessage, realTime, serviceName, machineName])

  return {
    metrics,
    loading,
    error,
    refetch: fetchMetrics
  }
}

/**
 * Hook for fetching machine-level metrics across all machines
 *
 * @param {object} options - Configuration options
 * @param {boolean} options.realTime - Enable real-time WebSocket updates (default: true)
 * @param {number} options.refreshInterval - Auto-refresh interval in ms (default: 10000)
 * @returns {object} - { metrics, loading, error, refetch }
 *
 * @typedef {Object} MachineMetrics
 * @property {string} machine - Machine name/identifier
 * @property {number} cpu_percent - CPU usage percentage (0-100)
 * @property {number} memory_used_mb - Memory used in megabytes
 * @property {number} memory_total_mb - Total memory in megabytes
 * @property {number} memory_percent - Calculated memory percentage (0-100)
 * @property {number} disk_used_gb - Disk space used in gigabytes
 * @property {number} disk_total_gb - Total disk space in gigabytes
 * @property {number} disk_percent - Calculated disk percentage (0-100)
 * @property {string} timestamp - ISO timestamp of when metrics were collected
 * @property {string} [status] - Optional status: "ok" | "error"
 * @property {string} [error] - Optional error message if status is "error"
 */
export function useAllMetrics(options = {}) {
  const { realTime = true, refreshInterval = 10000 } = options

  const [metrics, setMetrics] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  // Build authenticated WebSocket URL (token attached as ?token= query param;
  // backend reads it via auth.websocket.authenticate_websocket).
  const wsUrl = typeof window !== 'undefined' ? buildAuthedWsUrl('/ws') : null

  const { lastMessage } = useWebSocket(wsUrl)

  /**
   * Calculate derived metrics for machine data
   * @param {Object} machineData - Raw machine metrics from backend
   * @returns {MachineMetrics} - Enriched machine metrics with calculated percentages
   */
  const enrichMachineMetrics = useCallback((machineData) => {
    // Handle error states gracefully
    if (!machineData || machineData.status === 'error') {
      return {
        ...machineData,
        memory_percent: 0,
        disk_percent: 0,
        cpu_percent: machineData?.cpu_percent || 0
      }
    }

    // Calculate derived percentages if not already provided by backend
    const memory_percent = machineData.memory_percent !== undefined
      ? machineData.memory_percent
      : (machineData.memory_total_mb > 0
          ? (machineData.memory_used_mb / machineData.memory_total_mb) * 100
          : 0)

    const disk_percent = machineData.disk_percent !== undefined
      ? machineData.disk_percent
      : (machineData.disk_total_gb > 0
          ? (machineData.disk_used_gb / machineData.disk_total_gb) * 100
          : 0)

    return {
      ...machineData,
      memory_percent: Math.round(memory_percent * 100) / 100, // Round to 2 decimal places
      disk_percent: Math.round(disk_percent * 100) / 100,
      cpu_percent: machineData.cpu_percent || 0
    }
  }, [])

  const fetchAllMetrics = useCallback(async () => {
    try {
      setLoading(true)
      setError(null)

      // Use the authenticated client (raw fetch bypasses the Bearer
      // interceptor and 401s on every poll when KEYCLOAK_ENABLED=true).
      const data = await getAllMetrics()

      // Enrich the metrics array with calculated percentages
      const enrichedMetrics = Array.isArray(data)
        ? data.map(enrichMachineMetrics)
        : []

      setMetrics(enrichedMetrics)
    } catch (err) {
      console.error('Error fetching all metrics:', err)
      setError(err.message)
      // Set empty array on error to prevent UI issues
      setMetrics([])
    } finally {
      setLoading(false)
    }
  }, [enrichMachineMetrics])

  useEffect(() => {
    fetchAllMetrics()
  }, [fetchAllMetrics])

  useEffect(() => {
    if (!realTime || !refreshInterval) return

    const interval = setInterval(() => {
      fetchAllMetrics()
    }, refreshInterval)

    return () => clearInterval(interval)
  }, [realTime, refreshInterval, fetchAllMetrics])

  // Handle WebSocket updates for machine-level metrics
  useEffect(() => {
    if (!lastMessage || !realTime) return

    try {
      const data = JSON.parse(lastMessage.data)

      // Handle machine-level metrics updates
      if (data.type === 'metrics_update' && data.machine) {
        setMetrics(prevMetrics => {
          const machineIndex = prevMetrics.findIndex(m => m.machine === data.machine)

          if (machineIndex >= 0) {
            // Update existing machine metrics
            const updatedMetrics = [...prevMetrics]
            updatedMetrics[machineIndex] = enrichMachineMetrics({
              ...data.metrics,
              machine: data.machine,
              timestamp: data.timestamp || new Date().toISOString()
            })
            return updatedMetrics
          } else {
            // Add new machine metrics
            return [...prevMetrics, enrichMachineMetrics({
              ...data.metrics,
              machine: data.machine,
              timestamp: data.timestamp || new Date().toISOString()
            })]
          }
        })
      }

      // Also handle batch updates if backend sends all machines at once
      if (data.type === 'all_metrics_update' && Array.isArray(data.metrics)) {
        setMetrics(data.metrics.map(enrichMachineMetrics))
      }
    } catch (err) {
      console.error('Error processing WebSocket message:', err)
      // Don't update state on WebSocket errors to preserve last good data
    }
  }, [lastMessage, realTime, enrichMachineMetrics])

  return {
    metrics,
    loading,
    error,
    refetch: fetchAllMetrics
  }
}
