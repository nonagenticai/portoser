import React, { useState } from 'react'
import { X, Activity, Clock, Bell } from 'lucide-react'
import ResourceMetrics from './ResourceMetrics'
import MetricsChart from './MetricsChart'
import UptimeStats from './UptimeStats'
import UptimeTimeline from './UptimeTimeline'
import UptimeHistory from './UptimeHistory'
import { useMetrics } from '../../hooks/useMetrics'
import { useUptime } from '../../hooks/useUptime'
import clsx from 'clsx'

/**
 * ServiceMonitoringPanel Component
 * Comprehensive monitoring panel with tabbed interface
 */
function ServiceMonitoringPanel({ service, machine, onClose, onAction }) {
  const [activeTab, setActiveTab] = useState('metrics')
  const [metricsTimeRange, setMetricsTimeRange] = useState('1h')
  const [uptimeTimeRange, setUptimeTimeRange] = useState('7d')

  const { metrics, loading: metricsLoading, error: metricsError, refetch: refetchMetrics } = useMetrics(
    service.name,
    service.machine_name || machine,
    {
      timeRange: metricsTimeRange,
      realTime: true
    }
  )

  const { uptime, loading: uptimeLoading, error: uptimeError, refetch: refetchUptime } = useUptime(
    service.name,
    service.machine_name || machine,
    {
      timeRange: uptimeTimeRange,
      realTime: true
    }
  )

  const tabs = [
    { id: 'metrics', label: 'Metrics', icon: Activity },
    { id: 'uptime', label: 'Uptime', icon: Clock },
    { id: 'alerts', label: 'Alerts', icon: Bell, disabled: true }
  ]

  return (
    <div className="fixed inset-0 z-50 overflow-hidden bg-black bg-opacity-50 flex items-center justify-center p-4">
      <div className="bg-white rounded-lg shadow-2xl max-w-7xl w-full max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="px-6 py-4 border-b border-gray-200">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-2xl font-bold text-gray-900">Service Monitoring</h2>
              <p className="text-sm text-gray-500 mt-1">
                {service.name} on {service.machine_name || machine}
              </p>
            </div>

            {/* Quick Actions */}
            <div className="flex items-center space-x-3">
              {onAction && (
                <>
                  <button
                    onClick={() => onAction('restart')}
                    className="px-3 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-lg transition-colors"
                  >
                    Restart
                  </button>
                  <button
                    onClick={() => onAction('logs')}
                    className="px-3 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-lg transition-colors"
                  >
                    View Logs
                  </button>
                </>
              )}

              <button
                onClick={onClose}
                className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
              >
                <X className="w-5 h-5 text-gray-600" />
              </button>
            </div>
          </div>

          {/* Tabs */}
          <div className="flex space-x-1 mt-4">
            {tabs.map(tab => (
              <button
                key={tab.id}
                onClick={() => !tab.disabled && setActiveTab(tab.id)}
                disabled={tab.disabled}
                className={clsx(
                  'flex items-center space-x-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors',
                  {
                    'bg-blue-50 text-blue-700': activeTab === tab.id,
                    'text-gray-600 hover:bg-gray-100': activeTab !== tab.id && !tab.disabled,
                    'text-gray-400 cursor-not-allowed': tab.disabled
                  }
                )}
              >
                <tab.icon className="w-4 h-4" />
                <span>{tab.label}</span>
                {tab.disabled && (
                  <span className="text-xs bg-gray-200 px-2 py-0.5 rounded">Soon</span>
                )}
              </button>
            ))}
          </div>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6">
          {/* Metrics Tab */}
          {activeTab === 'metrics' && (
            <div className="space-y-6">
              {metricsError && (
                <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-red-700">
                  Error loading metrics: {metricsError}
                </div>
              )}

              {/* Current Metrics */}
              <div>
                <h3 className="text-lg font-semibold text-gray-900 mb-4">Current Resources</h3>
                <div className="bg-white border border-gray-200 rounded-lg p-6">
                  <ResourceMetrics
                    metrics={metrics?.current}
                    loading={metricsLoading}
                    onRefresh={refetchMetrics}
                  />
                </div>
              </div>

              {/* Historical Chart */}
              <div>
                <MetricsChart
                  data={metrics?.historical}
                  timeRange={metricsTimeRange}
                  onTimeRangeChange={setMetricsTimeRange}
                  height={400}
                />
              </div>
            </div>
          )}

          {/* Uptime Tab */}
          {activeTab === 'uptime' && (
            <div className="space-y-6">
              {uptimeError && (
                <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-red-700">
                  Error loading uptime data: {uptimeError}
                </div>
              )}

              {/* Uptime Stats */}
              <div>
                <UptimeStats uptime={uptime} loading={uptimeLoading} />
              </div>

              {/* Uptime Timeline */}
              <div>
                <UptimeTimeline
                  events={uptime?.events || []}
                  timeRange={uptimeTimeRange}
                  onTimeRangeChange={setUptimeTimeRange}
                />
              </div>

              {/* Event History */}
              <div>
                <UptimeHistory
                  serviceName={service.name}
                  machineName={service.machine_name || machine}
                />
              </div>
            </div>
          )}

          {/* Alerts Tab (Future) */}
          {activeTab === 'alerts' && (
            <div className="flex items-center justify-center h-64 text-gray-500">
              <div className="text-center">
                <Bell className="w-12 h-12 mx-auto mb-3 opacity-50" />
                <p>Alert configuration coming soon</p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

export default ServiceMonitoringPanel
