import { useState, useEffect } from 'react'
import { fetchServices } from '../api/client'

/**
 * Custom hook for service discovery
 * Fetches the service-to-machine mapping to enable smart metric fetching
 * and eliminate 404 errors from invalid service/machine combinations
 *
 * @returns {object} - { serviceMap, loading, serviceRunsOnMachine }
 */
export function useServiceDiscovery() {
  const [serviceMap, setServiceMap] = useState({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    const fetchServiceMap = async () => {
      try {
        setLoading(true)
        setError(null)

        // Use the authenticated axios client (api/client.js) — raw fetch()
        // bypasses the Bearer-token interceptor and 401s on every poll
        // when KEYCLOAK_ENABLED=true.
        const services = await fetchServices()

        const map = {}
        services.forEach(service => {
          if (service.name && service.machine_name) {
            if (!map[service.name]) {
              map[service.name] = []
            }
            if (!map[service.name].includes(service.machine_name)) {
              map[service.name].push(service.machine_name)
            }
          }
        })

        setServiceMap(map)
      } catch (err) {
        console.error('Error fetching service discovery map:', err)
        setError(err.message)
        // Keep existing map on error to avoid breaking UI
      } finally {
        setLoading(false)
      }
    }

    fetchServiceMap()

    // Refresh service map every 30 seconds
    const interval = setInterval(fetchServiceMap, 30000)

    return () => clearInterval(interval)
  }, [])

  /**
   * Check if a service runs on a specific machine
   * @param {string} service - Service name
   * @param {string} machine - Machine name
   * @returns {boolean} - True if service runs on machine, false otherwise
   */
  const serviceRunsOnMachine = (service, machine) => {
    if (!service || !machine) return false
    return serviceMap[service]?.includes(machine) || false
  }

  return {
    serviceMap,
    loading,
    error,
    serviceRunsOnMachine
  }
}
