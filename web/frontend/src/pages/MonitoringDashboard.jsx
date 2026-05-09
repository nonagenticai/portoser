import React, { useState } from 'react'
import { Activity, Cpu, MemoryStick, TrendingUp, Search, Filter, RefreshCw, HardDrive, Server } from 'lucide-react'
import ResourceMetrics from '../components/Metrics/ResourceMetrics'
import ServiceMonitoringPanel from '../components/Metrics/ServiceMonitoringPanel'
import SLAIndicator from '../components/Metrics/SLAIndicator'
import { useAllMetrics } from '../hooks/useMetrics'
import { useQuery } from '@tanstack/react-query'
import { fetchServices } from '../api/client'
import { safeToFixed, safePercent } from '../utils/formatters'
import clsx from 'clsx'

/**
 * MonitoringDashboard Page
 * Overview of all service metrics and monitoring
 */
function MonitoringDashboard() {
  const [searchQuery, setSearchQuery] = useState('')
  const [machineFilter, setMachineFilter] = useState(null)
  const [sortBy, setSortBy] = useState('name')
  const [selectedService, setSelectedService] = useState(null)
  const [showHighUsage, setShowHighUsage] = useState(false)

  const { metrics: allMetrics, loading: metricsLoading, error: metricsError, refetch } = useAllMetrics({
    realTime: true,
    refreshInterval: 10000
  })

  const { data: servicesData } = useQuery({
    queryKey: ['services'],
    queryFn: fetchServices,
    refetchInterval: 30000
  })

  const services = servicesData || []

  // Combine services with their metrics
  const servicesWithMetrics = services.map(service => {
    const serviceMetrics = allMetrics.find(
      m => m.service === service.name && m.machine === service.machine_name
    )
    return {
      ...service,
      metrics: serviceMetrics
    }
  })

  // Calculate overview stats
  const overviewStats = calculateOverviewStats(allMetrics)

  // Get unique machines for filter
  const machines = [...new Set(services.map(s => s.machine_name))].filter(Boolean)

  // Calculate machine-level metrics
  const machineMetrics = calculateMachineMetrics(allMetrics, machines)

  // Track last updated time
  const [lastUpdated, setLastUpdated] = React.useState(new Date())
  React.useEffect(() => {
    if (!metricsLoading) {
      setLastUpdated(new Date())
    }
  }, [allMetrics, metricsLoading])

  // Filter and sort services
  const filteredServices = servicesWithMetrics
    .filter(service => {
      // Search filter
      if (searchQuery && !service.name.toLowerCase().includes(searchQuery.toLowerCase())) {
        return false
      }

      // Machine filter
      if (machineFilter && service.machine_name !== machineFilter) {
        return false
      }

      // High usage filter
      if (showHighUsage) {
        const cpuHigh = service.metrics?.cpu_percent >= 70
        const memoryHigh = service.metrics?.memory_percent >= 70
        if (!cpuHigh && !memoryHigh) {
          return false
        }
      }

      return true
    })
    .sort((a, b) => {
      switch (sortBy) {
        case 'cpu':
          return (b.metrics?.cpu_percent || 0) - (a.metrics?.cpu_percent || 0)
        case 'memory':
          return (b.metrics?.memory_percent || 0) - (a.metrics?.memory_percent || 0)
        case 'uptime':
          return (b.metrics?.uptime_percent || 0) - (a.metrics?.uptime_percent || 0)
        case 'name':
        default:
          return a.name.localeCompare(b.name)
      }
    })

  return (
    <div className="min-h-screen bg-gray-50">
      <div className="container mx-auto px-4 py-8">
        {/* Header */}
        <div className="mb-8">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h1 className="text-3xl font-bold text-gray-900">Monitoring Dashboard</h1>
              <p className="text-gray-600 mt-1">Real-time service metrics and uptime tracking</p>
            </div>

            <div className="flex items-center space-x-3">
              <div className="text-sm text-gray-500">
                Last Updated: <span className="font-medium">{lastUpdated.toLocaleTimeString()}</span>
              </div>
              <button
                onClick={() => refetch()}
                disabled={metricsLoading}
                className={clsx(
                  "flex items-center space-x-2 px-4 py-2 bg-white border border-gray-300 rounded-lg transition-colors",
                  {
                    "hover:bg-gray-50": !metricsLoading,
                    "opacity-50 cursor-not-allowed": metricsLoading
                  }
                )}
              >
                <RefreshCw className={clsx("w-4 h-4", { "animate-spin": metricsLoading })} />
                <span>Refresh</span>
              </button>
            </div>
          </div>

          {/* Overview Cards */}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
            <OverviewCard
              icon={Activity}
              label="Services Monitored"
              value={services.length.toString()}
              color="blue"
            />
            <OverviewCard
              icon={Cpu}
              label="Average CPU"
              value={safePercent(overviewStats.avgCpu)}
              color={overviewStats.avgCpu >= 70 ? 'red' : 'green'}
            />
            <OverviewCard
              icon={MemoryStick}
              label="Average Memory"
              value={safePercent(overviewStats.avgMemory)}
              color={overviewStats.avgMemory >= 70 ? 'red' : 'green'}
            />
            <OverviewCard
              icon={TrendingUp}
              label="Overall Availability"
              value={`${safeToFixed(overviewStats.avgUptime, 2)}%`}
              color={overviewStats.avgUptime >= 99.9 ? 'green' : 'yellow'}
            />
          </div>
        </div>

        {/* Machine Load Cards */}
        {machines.length > 0 && (
          <div className="mb-8">
            <h2 className="text-xl font-semibold text-gray-900 mb-4">Machine Overview</h2>
            {metricsError ? (
              <div className="bg-red-50 border border-red-200 rounded-lg p-4 text-red-700">
                Error loading machine metrics: {metricsError}
              </div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
                {metricsLoading && machineMetrics.length === 0 ? (
                  // Loading skeleton
                  [...Array(4)].map((_, i) => (
                    <div key={i} className="animate-pulse bg-white rounded-lg border border-gray-200 p-6 h-48"></div>
                  ))
                ) : (
                  machineMetrics.map(machine => (
                    <MachineLoadCard
                      key={machine.name}
                      machine={machine}
                    />
                  ))
                )}
              </div>
            )}
          </div>
        )}

        {/* Filters */}
        <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-4 mb-6">
          <div className="flex flex-wrap gap-4">
            {/* Search */}
            <div className="flex-1 min-w-[200px]">
              <div className="relative">
                <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-gray-400" />
                <input
                  type="text"
                  placeholder="Search services..."
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  className="w-full pl-10 pr-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>
            </div>

            {/* Machine Filter */}
            <div className="relative">
              <select
                value={machineFilter || ''}
                onChange={(e) => setMachineFilter(e.target.value || null)}
                className="appearance-none bg-white border border-gray-300 rounded-lg px-4 py-2 pr-10 focus:outline-none focus:ring-2 focus:ring-blue-500"
              >
                <option value="">All Machines</option>
                {machines.map(machine => (
                  <option key={machine} value={machine}>{machine}</option>
                ))}
              </select>
              <Filter className="absolute right-3 top-1/2 transform -translate-y-1/2 w-4 h-4 text-gray-500 pointer-events-none" />
            </div>

            {/* Sort By */}
            <select
              value={sortBy}
              onChange={(e) => setSortBy(e.target.value)}
              className="bg-white border border-gray-300 rounded-lg px-4 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value="name">Sort by Name</option>
              <option value="cpu">Sort by CPU</option>
              <option value="memory">Sort by Memory</option>
              <option value="uptime">Sort by Uptime</option>
            </select>

            {/* High Usage Toggle */}
            <button
              onClick={() => setShowHighUsage(!showHighUsage)}
              className={clsx(
                'px-4 py-2 rounded-lg font-medium transition-colors',
                {
                  'bg-red-100 text-red-700': showHighUsage,
                  'bg-gray-100 text-gray-700': !showHighUsage
                }
              )}
            >
              High Usage Only
            </button>
          </div>
        </div>

        {/* Service Grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {metricsLoading && services.length === 0 ? (
            // Loading skeleton
            [...Array(6)].map((_, i) => (
              <div key={i} className="animate-pulse bg-white rounded-lg border border-gray-200 p-6 h-64"></div>
            ))
          ) : filteredServices.length === 0 ? (
            // Empty state
            <div className="col-span-full text-center py-12 text-gray-500">
              <p>No services found matching your filters</p>
            </div>
          ) : (
            // Service cards
            filteredServices.map(service => (
              <ServiceMetricCard
                key={`${service.name}-${service.machine_name}`}
                service={service}
                onViewDetails={() => setSelectedService(service)}
                onViewMetrics={() => setSelectedService(service)}
              />
            ))
          )}
        </div>
      </div>

      {/* Service Monitoring Panel */}
      {selectedService && (
        <ServiceMonitoringPanel
          service={selectedService}
          machine={selectedService.machine_name}
          onClose={() => setSelectedService(null)}
        />
      )}
    </div>
  )
}

/**
 * OverviewCard Component
 */
function OverviewCard({ icon: Icon, label, value, color = 'gray' }) {
  const colorClasses = {
    blue: 'bg-blue-50 text-blue-600',
    green: 'bg-green-50 text-green-600',
    yellow: 'bg-yellow-50 text-yellow-600',
    red: 'bg-red-50 text-red-600',
    gray: 'bg-gray-50 text-gray-600'
  }

  return (
    <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
      <div className="flex items-center space-x-4">
        <div className={clsx('p-3 rounded-lg', colorClasses[color])}>
          <Icon className="w-6 h-6" />
        </div>
        <div>
          <div className="text-sm text-gray-600">{label}</div>
          <div className="text-2xl font-bold text-gray-900">{value}</div>
        </div>
      </div>
    </div>
  )
}

/**
 * ServiceMetricCard Component
 */
function ServiceMetricCard({ service, onViewDetails, onViewMetrics }) {
  const metrics = service.metrics

  return (
    <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6 hover:shadow-md transition-shadow">
      {/* Header */}
      <div className="flex items-start justify-between mb-4">
        <div>
          <h3 className="text-lg font-semibold text-gray-900">{service.name}</h3>
          <p className="text-sm text-gray-500">{service.machine_name}</p>
        </div>
        <div className={clsx('w-3 h-3 rounded-full', {
          'bg-green-500': service.status === 'running',
          'bg-red-500': service.status === 'stopped',
          'bg-gray-400': service.status === 'unknown'
        })} />
      </div>

      {/* Metrics */}
      {metrics ? (
        <div className="space-y-3 mb-4">
          <ResourceMetrics metrics={metrics} compact={true} />
        </div>
      ) : (
        <div className="text-sm text-gray-500 mb-4">No metrics available</div>
      )}

      {/* Uptime Badge */}
      {metrics?.uptime_percent !== undefined && (
        <div className="mb-4">
          <SLAIndicator availability={metrics.uptime_percent} compact={true} />
        </div>
      )}

      {/* Actions */}
      <div className="flex space-x-2">
        <button
          onClick={onViewDetails}
          className="flex-1 px-3 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-lg transition-colors"
        >
          View Details
        </button>
        <button
          onClick={onViewMetrics}
          className="flex-1 px-3 py-2 text-sm font-medium text-white bg-blue-600 hover:bg-blue-700 rounded-lg transition-colors"
        >
          View Metrics
        </button>
      </div>
    </div>
  )
}

/**
 * Calculate overview statistics
 */
function calculateOverviewStats(metrics) {
  if (!metrics || metrics.length === 0) {
    return {
      avgCpu: 0,
      avgMemory: 0,
      avgUptime: 0
    }
  }

  const avgCpu = metrics.reduce((sum, m) => sum + (m.cpu_percent || 0), 0) / metrics.length
  const avgMemory = metrics.reduce((sum, m) => sum + (m.memory_percent || 0), 0) / metrics.length
  const avgUptime = metrics.reduce((sum, m) => sum + (m.uptime_percent || 100), 0) / metrics.length

  return {
    avgCpu,
    avgMemory,
    avgUptime
  }
}

/**
 * Calculate machine-level metrics by aggregating service metrics
 */
function calculateMachineMetrics(allMetrics, machines) {
  return machines.map(machineName => {
    // Get all metrics for this machine
    const machineServiceMetrics = allMetrics.filter(m => m.machine === machineName)

    if (machineServiceMetrics.length === 0) {
      return {
        name: machineName,
        cpuPercent: 0,
        memoryUsedMB: 0,
        memoryTotalMB: 0,
        memoryPercent: 0,
        diskUsedGB: 0,
        diskTotalGB: 0,
        diskPercent: 0,
        status: 'unknown',
        serviceCount: 0
      }
    }

    // Aggregate CPU (average across services)
    const avgCpu = machineServiceMetrics.reduce((sum, m) => sum + (m.cpu_percent || 0), 0) / machineServiceMetrics.length

    // Aggregate Memory (sum of used, take max of total if available)
    const totalMemoryUsedMB = machineServiceMetrics.reduce((sum, m) => sum + (m.memory_mb || 0), 0)
    const memoryTotalMB = Math.max(...machineServiceMetrics.map(m => m.memory_total_mb || 0))
    const memoryPercent = memoryTotalMB > 0 ? (totalMemoryUsedMB / memoryTotalMB) * 100 : 0

    // Aggregate Disk (sum of used, take max of total if available)
    const totalDiskUsedGB = machineServiceMetrics.reduce((sum, m) => sum + ((m.disk_mb || 0) / 1024), 0)
    const diskTotalGB = Math.max(...machineServiceMetrics.map(m => (m.disk_total_mb || 0) / 1024))
    const diskPercent = diskTotalGB > 0 ? (totalDiskUsedGB / diskTotalGB) * 100 : 0

    // Determine status (error if any service has high usage or errors)
    const hasError = machineServiceMetrics.some(m =>
      m.cpu_percent >= 90 ||
      m.memory_percent >= 90 ||
      m.status === 'error'
    )
    const status = hasError ? 'error' : 'ok'

    return {
      name: machineName,
      cpuPercent: avgCpu,
      memoryUsedMB: totalMemoryUsedMB,
      memoryTotalMB: memoryTotalMB,
      memoryPercent: memoryPercent,
      diskUsedGB: totalDiskUsedGB,
      diskTotalGB: diskTotalGB,
      diskPercent: diskPercent,
      status: status,
      serviceCount: machineServiceMetrics.length
    }
  })
}

/**
 * MachineLoadCard Component
 * Displays machine-level resource usage overview
 */
function MachineLoadCard({ machine }) {
  const formatBytes = (mb) => {
    if (mb < 1024) return `${Math.round(mb)} MB`
    return `${safeToFixed(mb / 1024, 1)} GB`
  }

  const formatGB = (gb) => `${safeToFixed(gb, 1)} GB`

  const getStatusColor = () => {
    if (machine.status === 'error') return 'bg-red-500'
    if (machine.status === 'warning') return 'bg-yellow-500'
    return 'bg-green-500'
  }

  const getUsageColor = (percent) => {
    if (percent >= 90) return 'bg-red-500'
    if (percent >= 70) return 'bg-yellow-500'
    return 'bg-blue-500'
  }

  return (
    <div className="bg-white rounded-lg shadow-sm border border-gray-200 p-6 hover:shadow-md transition-shadow">
      {/* Header */}
      <div className="flex items-start justify-between mb-4">
        <div className="flex items-center space-x-2">
          <div className="p-2 rounded-lg bg-blue-50">
            <Server className="w-5 h-5 text-blue-600" />
          </div>
          <div>
            <h3 className="font-semibold text-gray-900">{machine.name}</h3>
            <p className="text-xs text-gray-500">{machine.serviceCount} services</p>
          </div>
        </div>
        <div
          className={clsx('w-3 h-3 rounded-full', getStatusColor())}
          title={machine.status === 'error' ? 'High resource usage detected' : 'Normal operation'}
        />
      </div>

      {/* CPU Usage */}
      <div className="mb-3">
        <div className="flex items-center justify-between mb-1">
          <div className="flex items-center space-x-1 text-sm text-gray-600">
            <Cpu className="w-4 h-4" />
            <span>CPU</span>
          </div>
          <span className="text-sm font-medium text-gray-900">
            {safePercent(machine.cpuPercent)}
          </span>
        </div>
        <div className="w-full bg-gray-200 rounded-full h-2">
          <div
            className={clsx('h-2 rounded-full transition-all', getUsageColor(machine.cpuPercent))}
            style={{ width: `${Math.min(machine.cpuPercent, 100)}%` }}
          />
        </div>
      </div>

      {/* Memory Usage */}
      <div className="mb-3">
        <div className="flex items-center justify-between mb-1">
          <div className="flex items-center space-x-1 text-sm text-gray-600">
            <MemoryStick className="w-4 h-4" />
            <span>Memory</span>
          </div>
          <span className="text-sm font-medium text-gray-900">
            {machine.memoryTotalMB > 0
              ? `${formatBytes(machine.memoryUsedMB)} / ${formatBytes(machine.memoryTotalMB)}`
              : formatBytes(machine.memoryUsedMB)
            }
          </span>
        </div>
        <div className="w-full bg-gray-200 rounded-full h-2">
          <div
            className={clsx('h-2 rounded-full transition-all', getUsageColor(machine.memoryPercent))}
            style={{ width: `${Math.min(machine.memoryPercent, 100)}%` }}
          />
        </div>
        {machine.memoryTotalMB > 0 && (
          <div className="text-xs text-gray-500 mt-1">
            {safePercent(machine.memoryPercent)}
          </div>
        )}
      </div>

      {/* Disk Usage */}
      <div>
        <div className="flex items-center justify-between mb-1">
          <div className="flex items-center space-x-1 text-sm text-gray-600">
            <HardDrive className="w-4 h-4" />
            <span>Disk</span>
          </div>
          <span className="text-sm font-medium text-gray-900">
            {machine.diskTotalGB > 0
              ? `${formatGB(machine.diskUsedGB)} / ${formatGB(machine.diskTotalGB)}`
              : formatGB(machine.diskUsedGB)
            }
          </span>
        </div>
        <div className="w-full bg-gray-200 rounded-full h-2">
          <div
            className={clsx('h-2 rounded-full transition-all', getUsageColor(machine.diskPercent))}
            style={{ width: `${Math.min(machine.diskPercent, 100)}%` }}
          />
        </div>
        {machine.diskTotalGB > 0 && (
          <div className="text-xs text-gray-500 mt-1">
            {safePercent(machine.diskPercent)}
          </div>
        )}
      </div>
    </div>
  )
}

export default MonitoringDashboard
