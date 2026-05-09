import { useState, useEffect, useCallback } from 'react'
import { useWebSocket } from './useWebSocket.js'
import { buildAuthedWsUrl } from '../api/client.js'

/**
 * Custom hook for fetching and subscribing to service uptime data
 * Provides real-time uptime updates via WebSocket
 *
 * @param {string} serviceName - Name of the service
 * @param {string} machineName - Name of the machine hosting the service
 * @param {object} options - Configuration options
 * @param {string} options.timeRange - Time range for history (24h, 7d, 30d)
 * @param {boolean} options.realTime - Enable real-time WebSocket updates
 * @returns {object} - { uptime, loading, error, refetch }
 */
export function useUptime(serviceName, machineName, options = {}) {
  const {
    timeRange = '7d',
    realTime = true
  } = options

  const [uptime, setUptime] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  // Authenticated WS URL — token in ?token= query string (browser WS API
  // doesn't allow custom headers; backend reads it server-side).
  const wsUrl = typeof window !== 'undefined' ? buildAuthedWsUrl('/ws') : null

  const { lastMessage } = useWebSocket(wsUrl)

  const fetchUptime = useCallback(async () => {
    if (!serviceName || !machineName) return

    try {
      setLoading(true)
      setError(null)

      const response = await fetch(
        `/api/uptime/${serviceName}/${machineName}?timeRange=${timeRange}`
      )

      if (!response.ok) {
        throw new Error(`Failed to fetch uptime: ${response.statusText}`)
      }

      const data = await response.json()
      setUptime(data)
    } catch (err) {
      console.error('Error fetching uptime:', err)
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }, [serviceName, machineName, timeRange])

  useEffect(() => {
    fetchUptime()
  }, [fetchUptime])

  // Handle WebSocket messages for real-time uptime events
  useEffect(() => {
    if (!lastMessage || !realTime) return

    try {
      const data = JSON.parse(lastMessage.data)

      if (
        data.type === 'uptime_event' &&
        data.service === serviceName &&
        data.machine === machineName
      ) {
        // Refetch uptime data when an event occurs
        fetchUptime()
      }
    } catch (err) {
      console.error('Error processing WebSocket message:', err)
    }
  }, [lastMessage, realTime, serviceName, machineName, fetchUptime])

  return {
    uptime,
    loading,
    error,
    refetch: fetchUptime
  }
}

/**
 * Hook for fetching uptime events/history
 */
export function useUptimeEvents(serviceName, machineName, options = {}) {
  const {
    limit = 50,
    eventType = null,
    realTime = true
  } = options

  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [hasMore, setHasMore] = useState(true)

  // Authenticated WS URL — token in ?token= query string (browser WS API
  // doesn't allow custom headers; backend reads it server-side).
  const wsUrl = typeof window !== 'undefined' ? buildAuthedWsUrl('/ws') : null

  const { lastMessage } = useWebSocket(wsUrl)

  const fetchEvents = useCallback(async (offset = 0) => {
    if (!serviceName || !machineName) return

    try {
      setLoading(true)
      setError(null)

      const params = new URLSearchParams({
        limit: limit.toString(),
        offset: offset.toString()
      })

      if (eventType) {
        params.append('eventType', eventType)
      }

      const response = await fetch(
        `/api/uptime/${serviceName}/${machineName}/events?${params}`
      )

      if (!response.ok) {
        throw new Error(`Failed to fetch uptime events: ${response.statusText}`)
      }

      const data = await response.json()

      if (offset === 0) {
        setEvents(data.events)
      } else {
        setEvents(prev => [...prev, ...data.events])
      }

      setHasMore(data.hasMore || false)
    } catch (err) {
      console.error('Error fetching uptime events:', err)
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }, [serviceName, machineName, limit, eventType])

  useEffect(() => {
    fetchEvents(0)
  }, [fetchEvents])

  // Handle new events via WebSocket
  useEffect(() => {
    if (!lastMessage || !realTime) return

    try {
      const data = JSON.parse(lastMessage.data)

      if (
        data.type === 'uptime_event' &&
        data.service === serviceName &&
        data.machine === machineName
      ) {
        // Add new event to the beginning of the list
        setEvents(prev => [data.event, ...prev])
      }
    } catch (err) {
      console.error('Error processing WebSocket message:', err)
    }
  }, [lastMessage, realTime, serviceName, machineName])

  const loadMore = useCallback(() => {
    if (!loading && hasMore) {
      fetchEvents(events.length)
    }
  }, [loading, hasMore, events.length, fetchEvents])

  return {
    events,
    loading,
    error,
    hasMore,
    loadMore,
    refetch: () => fetchEvents(0)
  }
}
