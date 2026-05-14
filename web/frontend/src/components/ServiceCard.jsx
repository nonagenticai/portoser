import React, { useState } from 'react'
import { useDrag } from 'react-dnd'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Package, Database, Box, Clock, Activity, Cpu, MemoryStick } from 'lucide-react'
import Tooltip from './Tooltip'
import ContextMenu from './ContextMenu'
import HealthIndicator from './HealthIndicator'
import ServiceInfoPanel from './ServiceInfoPanel'
import { IntelligentDeploymentPanel } from './IntelligentDeployment'
import DiagnosticsPanel from './Diagnostics/DiagnosticsPanel'
import ServiceMonitoringPanel from './Metrics/ServiceMonitoringPanel'
import {
  startService,
  stopService,
  restartService,
  rebuildService,
  getServiceMetrics
} from '../api/client'
import { useServiceDiscovery } from '../hooks/useServiceDiscovery'
import { safeToFixed, safePercent } from '../utils/formatters'
import clsx from 'clsx'

function ServiceCard({ service, healthData, isPending = false }) {
  const [contextMenu, setContextMenu] = useState(null)
  const [showInfo, setShowInfo] = useState(false)
  const [showIntelligentDeploy, setShowIntelligentDeploy] = useState(false)
  const [showDiagnostics, setShowDiagnostics] = useState(false)
  const [showMonitoring, setShowMonitoring] = useState(false)
  const queryClient = useQueryClient()

  const [{ isDragging }, drag] = useDrag({
    type: 'SERVICE',
    item: { service },
    collect: (monitor) => ({
      isDragging: monitor.isDragging(),
    }),
  })

  // Service discovery to check if metrics should be fetched
  const { serviceRunsOnMachine, loading: discoveryLoading } = useServiceDiscovery()

  // Fetch metrics for mini display - only if service runs on this machine
  const shouldFetchMetrics = !isPending &&
                            !!service.machine_name &&
                            !discoveryLoading &&
                            serviceRunsOnMachine(service.name, service.machine_name)

  const { data: metricsData } = useQuery({
    queryKey: ['service-metrics', service.name, service.machine_name],
    queryFn: () => getServiceMetrics(service.name, service.machine_name, '1h'),
    refetchInterval: 10000,
    enabled: shouldFetchMetrics,
  })

  // Service action mutations
  const startMutation = useMutation({
    mutationFn: () => startService(service.name),
    onSuccess: () => {
      queryClient.invalidateQueries(['service-health', service.name])
      queryClient.invalidateQueries(['services'])
    },
  })

  const stopMutation = useMutation({
    mutationFn: () => stopService(service.name, false),
    onSuccess: () => {
      queryClient.invalidateQueries(['service-health', service.name])
      queryClient.invalidateQueries(['services'])
    },
  })

  const restartMutation = useMutation({
    mutationFn: () => restartService(service.name),
    onSuccess: () => {
      queryClient.invalidateQueries(['service-health', service.name])
      queryClient.invalidateQueries(['services'])
    },
  })

  const rebuildMutation = useMutation({
    mutationFn: () => rebuildService(service.name),
    onSuccess: () => {
      queryClient.invalidateQueries(['service-health', service.name])
      queryClient.invalidateQueries(['services'])
    },
  })

  const getServiceIcon = (type) => {
    switch (type) {
      case 'docker':
        return <Box className="w-4 h-4" />
      case 'native':
        return <Database className="w-4 h-4" />
      case 'local':
        return <Package className="w-4 h-4" />
      default:
        return <Package className="w-4 h-4" />
    }
  }

  const getTypeTooltip = (type) => {
    switch (type) {
      case 'docker':
        return 'Docker: Containerized application. Can be moved between any machines with Docker installed.'
      case 'native':
        return 'Native: System service installed via Homebrew or package manager. Requires dependencies on target machine.'
      case 'local':
        return 'Local: Python application running with Poetry/UV. Managed via virtual environment.'
      default:
        return 'Service deployment type'
    }
  }

  const getTypeColor = (type) => {
    switch (type) {
      case 'docker':
        return 'bg-blue-100 text-blue-700 border-blue-200'
      case 'native':
        return 'bg-green-100 text-green-700 border-green-200'
      case 'local':
        return 'bg-purple-100 text-purple-700 border-purple-200'
      default:
        return 'bg-gray-100 text-gray-700 border-gray-200'
    }
  }

  const handleContextMenu = (e) => {
    e.preventDefault()
    e.stopPropagation()

    const isDocker = service.deployment_type === 'docker'
    const healthStatus = healthData?.status || 'unknown'
    const isRunning = healthStatus === 'healthy' || healthStatus === 'unhealthy'

    const items = [
      {
        label: 'Service Info',
        icon: 'info',
        action: 'info',
      },
      { type: 'divider' },
      {
        label: 'View Metrics',
        icon: 'activity',
        action: 'view-metrics',
      },
      {
        label: 'Run Diagnostics',
        icon: 'stethoscope',
        action: 'diagnostics',
      },
      {
        label: 'Intelligent Deploy',
        icon: 'sparkles',
        action: 'intelligent-deploy',
      },
      { type: 'divider' },
    ]

    // Add appropriate actions based on deployment type and status
    if (isDocker) {
      if (isRunning) {
        items.push(
          {
            label: 'Restart',
            icon: 'restart',
            action: 'restart',
          },
          {
            label: 'Stop',
            icon: 'stop',
            action: 'stop',
          },
          { type: 'divider' },
          {
            label: 'Rebuild',
            icon: 'rebuild',
            action: 'rebuild',
          },
          {
            label: 'Compose Down',
            icon: 'down',
            action: 'down',
            danger: true,
          }
        )
      } else {
        items.push(
          {
            label: 'Start',
            icon: 'start',
            action: 'start',
          },
          {
            label: 'Rebuild & Start',
            icon: 'rebuild',
            action: 'rebuild',
          }
        )
      }
    } else {
      // Native/Local services
      if (isRunning) {
        items.push(
          {
            label: 'Restart',
            icon: 'restart',
            action: 'restart',
          },
          {
            label: 'Stop',
            icon: 'stop',
            action: 'stop',
          }
        )
      } else {
        items.push({
          label: 'Start',
          icon: 'start',
          action: 'start',
        })
      }
    }

    setContextMenu({
      x: e.clientX,
      y: e.clientY,
      items,
    })
  }

  const handleMenuItemClick = (item) => {
    switch (item.action) {
      case 'info':
        setShowInfo(true)
        break
      case 'view-metrics':
        setShowMonitoring(true)
        break
      case 'diagnostics':
        setShowDiagnostics(true)
        break
      case 'intelligent-deploy':
        setShowIntelligentDeploy(true)
        break
      case 'start':
        startMutation.mutate()
        break
      case 'stop':
        stopMutation.mutate()
        break
      case 'restart':
        restartMutation.mutate()
        break
      case 'rebuild':
        if (confirm(`Rebuild ${service.name}? This will rebuild the Docker image and restart the service.`)) {
          rebuildMutation.mutate()
        }
        break
      case 'down':
        if (confirm(`Run docker-compose down for ${service.name}? This will stop and remove containers.`)) {
          stopMutation.mutate()
        }
        break
    }
  }

  const healthStatus = healthData?.status || 'unknown'
  const isLoading = startMutation.isPending || stopMutation.isPending ||
                     restartMutation.isPending || rebuildMutation.isPending

  return (
    <>
      <Tooltip
        content={`${service.name} - ${getTypeTooltip(service.deployment_type)}. ${isPending ? 'Pending deployment - will be deployed when you click Deploy Changes.' : 'Right-click for actions or drag to another machine.'}`}
        position="right"
      >
        <div
          ref={drag}
          onContextMenu={handleContextMenu}
          className={clsx(
            'relative p-3 border rounded-lg cursor-move transition-all duration-200 hover:shadow-md',
            getTypeColor(service.deployment_type),
            {
              'opacity-50': isDragging,
              'ring-2 ring-warning ring-offset-2': isPending,
              'ring-2 ring-blue-400': isLoading,
            }
          )}
        >
          {/* Health Indicator - Top Right */}
          <div className="absolute top-2 right-2">
            <HealthIndicator status={isPending ? 'unknown' : healthStatus} />
          </div>

          <div className="flex items-center justify-between pr-4">
            <div className="flex items-center space-x-2 flex-1 min-w-0">
              <Tooltip content={getTypeTooltip(service.deployment_type)}>
                <div className="cursor-help">
                  {getServiceIcon(service.deployment_type)}
                </div>
              </Tooltip>
              <div className="flex-1 min-w-0">
                <div className="font-medium text-sm truncate">{service.name}</div>
                {service.hostname && (
                  <Tooltip content={`Access this service at: ${service.hostname}`}>
                    <div className="text-xs opacity-75 truncate cursor-help">{service.hostname}</div>
                  </Tooltip>
                )}
              </div>
            </div>

            {isPending && (
              <Tooltip content="This service has pending changes. Click 'Deploy Changes' to apply.">
                <Clock className="w-4 h-4 text-warning shrink-0 ml-2 cursor-help" />
              </Tooltip>
            )}
          </div>

          <div className="mt-2 flex items-center justify-between text-xs">
            <span className="opacity-75">{service.deployment_type}</span>
            {isLoading && (
              <span className="text-blue-600 font-medium">Processing...</span>
            )}
          </div>

          {/* Mini Resource Bars */}
          {metricsData?.current && !isPending && (
            <div className="mt-3 space-y-1.5">
              <MiniResourceBar
                icon={Cpu}
                value={metricsData.current.cpu_percent}
                label="CPU"
              />
              <MiniResourceBar
                icon={MemoryStick}
                value={metricsData.current.memory_percent}
                label="Memory"
              />
            </div>
          )}

          {/* Uptime Badge */}
          {metricsData?.current?.uptime_percent !== undefined && !isPending && (
            <div className="mt-2 flex items-center space-x-1.5">
              <Activity className="w-3 h-3 text-green-600" />
              <span className="text-xs font-medium text-green-600">
                {safePercent(metricsData.current.uptime_percent)} uptime
              </span>
            </div>
          )}
        </div>
      </Tooltip>

      {contextMenu && (
        <ContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          items={contextMenu.items}
          onClose={() => setContextMenu(null)}
          onItemClick={handleMenuItemClick}
        />
      )}

      {showInfo && (
        <ServiceInfoPanel
          service={service}
          onClose={() => setShowInfo(false)}
        />
      )}

      {showIntelligentDeploy && (
        <IntelligentDeploymentPanel
          service={service}
          onClose={() => setShowIntelligentDeploy(false)}
        />
      )}

      {showDiagnostics && (
        <DiagnosticsPanel
          serviceName={service.name}
          machineName={service.machine_name}
          onClose={() => setShowDiagnostics(false)}
        />
      )}

      {showMonitoring && (
        <ServiceMonitoringPanel
          service={service}
          machine={service.machine_name}
          onClose={() => setShowMonitoring(false)}
        />
      )}
    </>
  )
}

/**
 * MiniResourceBar - Compact resource usage indicator
 */
function MiniResourceBar({ icon: Icon, value, label }) {
  const getColorClass = (percentage) => {
    if (percentage >= 90) return 'bg-red-500'
    if (percentage >= 70) return 'bg-yellow-500'
    return 'bg-green-500'
  }

  return (
    <div className="flex items-center space-x-2">
      <Icon className="w-3 h-3 text-gray-600" />
      <div className="flex-1">
        <div className="h-1.5 bg-gray-200 rounded-full overflow-hidden">
          <div
            className={clsx('h-full transition-all', getColorClass(value))}
            style={{ width: `${Math.min(value, 100)}%` }}
          />
        </div>
      </div>
      <span className="text-xs text-gray-600 w-8 text-right">
        {safeToFixed(value, 0)}%
      </span>
    </div>
  )
}

export default ServiceCard
