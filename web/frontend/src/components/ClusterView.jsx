import React from 'react'
import { useQuery } from '@tanstack/react-query'
import { fetchMachines, fetchServices, getAllHealthChecks } from '../api/client'
import MachineCard from './MachineCard'
import { Loader2 } from 'lucide-react'
import { useErrorHandler } from '../hooks/useErrorHandler'
import ErrorAlert from './ErrorAlert'

function ClusterView({ onServiceMove, pendingMoves }) {
  const { error, handleError, clearError } = useErrorHandler()

  const { data: machinesData, isLoading: loadingMachines, error: machinesError } = useQuery({
    queryKey: ['machines'],
    queryFn: fetchMachines,
    refetchInterval: 5000,
    onError: handleError,
  })

  const { data: servicesData, isLoading: loadingServices, error: servicesError } = useQuery({
    queryKey: ['services'],
    queryFn: fetchServices,
    refetchInterval: 5000,
    onError: handleError,
  })

  // Fetch health data for all services in bulk
  const { data: healthData, error: healthError } = useQuery({
    queryKey: ['all-health'],
    queryFn: getAllHealthChecks,
    refetchInterval: 10000,  // Check every 10 seconds
    onError: handleError,
  })

  if (loadingMachines || loadingServices) {
    return (
      <div className="flex items-center justify-center py-12">
        <Loader2 className="w-8 h-8 animate-spin text-primary" />
        <span className="ml-3 text-gray-600">Loading cluster...</span>
      </div>
    )
  }

  const machines = machinesData || []
  const services = servicesData || []
  const healthByService = {}

  // Index health data by service name
  if (healthData) {
    healthData.forEach(health => {
      healthByService[health.service] = health
    })
  }

  // Group services by machine
  const servicesByMachine = {}
  services.forEach(service => {
    const machine = service.current_host || 'unassigned'
    if (!servicesByMachine[machine]) {
      servicesByMachine[machine] = []
    }
    servicesByMachine[machine].push(service)
  })

  // Apply pending moves to the view
  const appliedServicesByMachine = { ...servicesByMachine }
  pendingMoves.forEach(move => {
    // Remove from old machine
    if (appliedServicesByMachine[move.from_machine]) {
      appliedServicesByMachine[move.from_machine] = appliedServicesByMachine[move.from_machine]
        .filter(s => s.name !== move.service_name)
    }

    // Add to new machine
    if (!appliedServicesByMachine[move.to_machine]) {
      appliedServicesByMachine[move.to_machine] = []
    }

    const service = services.find(s => s.name === move.service_name)
    if (service) {
      appliedServicesByMachine[move.to_machine].push({
        ...service,
        current_host: move.to_machine,
        pending: true
      })
    }
  })

  return (
    <div className="space-y-6">
      {error && <ErrorAlert error={error} onClose={clearError} />}

      <div className="flex items-center justify-between">
        <h2 className="text-xl font-semibold text-gray-900">Cluster Overview</h2>
        <div className="text-sm text-gray-600">
          {machines.length} machines • {services.length} services
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        {machines.map(machine => (
          <MachineCard
            key={machine.name}
            machine={machine}
            services={appliedServicesByMachine[machine.name] || []}
            healthByService={healthByService}
            onServiceMove={onServiceMove}
          />
        ))}
      </div>

      {/* Unassigned services */}
      {(appliedServicesByMachine['unassigned']?.length > 0 ||
        appliedServicesByMachine['null']?.length > 0) && (
        <div className="mt-8">
          <h3 className="text-lg font-medium text-gray-900 mb-4">Unassigned Services</h3>
          <MachineCard
            machine={{ name: 'unassigned', ip: '-', ssh_user: '-', roles: [] }}
            services={[
              ...(appliedServicesByMachine['unassigned'] || []),
              ...(appliedServicesByMachine['null'] || [])
            ]}
            healthByService={healthByService}
            onServiceMove={onServiceMove}
            isUnassigned
          />
        </div>
      )}
    </div>
  )
}

export default ClusterView
