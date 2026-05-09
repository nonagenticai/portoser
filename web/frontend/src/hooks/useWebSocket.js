import { useEffect, useRef, useState } from 'react'

const INITIAL_RECONNECT_DELAY_MS = 1000
const MAX_RECONNECT_DELAY_MS = 30000

// Exponential backoff with ±25% jitter. Doubling alone is enough to avoid
// hammering a recovering server; jitter keeps a swarm of clients from
// retrying in lock-step after a global outage.
function nextDelay(previousMs) {
  const doubled = Math.min(previousMs * 2, MAX_RECONNECT_DELAY_MS)
  const jitter = doubled * (Math.random() * 0.5 - 0.25)
  return Math.max(INITIAL_RECONNECT_DELAY_MS, Math.round(doubled + jitter))
}

export function useWebSocket(url) {
  const [status, setStatus] = useState('connecting')
  const [lastMessage, setLastMessage] = useState(null)
  const ws = useRef(null)
  const reconnectTimeout = useRef(null)
  const mountTimeout = useRef(null)
  const reconnectDelay = useRef(INITIAL_RECONNECT_DELAY_MS)

  useEffect(() => {
    // A null URL means "don't connect yet" (e.g., we don't have a token, or
    // the parent hasn't picked a deployment to subscribe to). Don't open the
    // socket; do clean up any leftover state from the prior URL.
    if (!url) {
      setStatus('idle')
      return
    }

    let isCleanedUp = false
    reconnectDelay.current = INITIAL_RECONNECT_DELAY_MS

    const connect = () => {
      if (isCleanedUp) return

      try {
        ws.current = new WebSocket(url)

        ws.current.onopen = () => {
          console.log('WebSocket connected')
          setStatus('connected')
          // Connection succeeded — reset the backoff window so the *next*
          // disconnect retries quickly rather than at the previous long delay.
          reconnectDelay.current = INITIAL_RECONNECT_DELAY_MS

          const pingInterval = setInterval(() => {
            if (ws.current?.readyState === WebSocket.OPEN) {
              ws.current.send('ping')
            }
          }, 30000)

          ws.current.pingInterval = pingInterval
        }

        ws.current.onmessage = (event) => {
          setLastMessage(event)
        }

        ws.current.onerror = (error) => {
          console.error('WebSocket error:', error)
          setStatus('error')
        }

        ws.current.onclose = () => {
          console.log('WebSocket disconnected')
          setStatus('disconnected')

          if (ws.current?.pingInterval) {
            clearInterval(ws.current.pingInterval)
          }

          if (!isCleanedUp) {
            const delay = reconnectDelay.current
            reconnectDelay.current = nextDelay(delay)
            console.log(`Attempting to reconnect in ${delay}ms`)
            reconnectTimeout.current = setTimeout(connect, delay)
          }
        }
      } catch (error) {
        console.error('Failed to create WebSocket:', error)
        setStatus('error')

        // The constructor itself failed (bad URL, blocked by CSP, etc.).
        // onclose won't fire, so schedule the next attempt manually.
        if (!isCleanedUp) {
          const delay = reconnectDelay.current
          reconnectDelay.current = nextDelay(delay)
          reconnectTimeout.current = setTimeout(connect, delay)
        }
      }
    }

    // Delay initial connection to avoid React StrictMode double-mount issues
    mountTimeout.current = setTimeout(() => {
      connect()
    }, 100)

    return () => {
      isCleanedUp = true

      if (mountTimeout.current) {
        clearTimeout(mountTimeout.current)
      }
      if (reconnectTimeout.current) {
        clearTimeout(reconnectTimeout.current)
      }

      if (ws.current) {
        if (ws.current.pingInterval) {
          clearInterval(ws.current.pingInterval)
        }
        if (ws.current.readyState === WebSocket.OPEN ||
            ws.current.readyState === WebSocket.CONNECTING) {
          ws.current.close()
        }
      }
    }
  }, [url])

  const sendMessage = (message) => {
    if (ws.current?.readyState === WebSocket.OPEN) {
      ws.current.send(typeof message === 'string' ? message : JSON.stringify(message))
    }
  }

  return {
    status,
    lastMessage,
    sendMessage,
  }
}

// Exposed for testing only. Not part of the public hook surface.
export const __test__ = { nextDelay, INITIAL_RECONNECT_DELAY_MS, MAX_RECONNECT_DELAY_MS }
