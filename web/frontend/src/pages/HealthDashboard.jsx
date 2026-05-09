import React, { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import {
  Activity,
  Heart,
  AlertTriangle,
  CheckCircle,
  Filter,
  Stethoscope,
  Clock,
  TrendingUp,
  Server
} from 'lucide-react'
import clsx from 'clsx'
import ServiceHealthCard from '../components/Diagnostics/ServiceHealthCard'
import ProblemFrequencyChart from '../components/Diagnostics/ProblemFrequencyChart'
import DiagnosticsPanel from '../components/Diagnostics/DiagnosticsPanel'
import { fetchServices, fetchMachines, getHealthDashboard, getProblemFrequency } from '../api/client'
import { useErrorHandler } from '../hooks/useErrorHandler'
import ErrorAlert from '../components/ErrorAlert'

function HealthDashboard() {
  const [statusFilter, setStatusFilter] = useState('all') // all, healthy, degraded, unhealthy
  const [machineFilter, setMachineFilter] = useState('all')
  const [roleFilter, setRoleFilter] = useState('all')
  const [showDiagnostics, setShowDiagnostics] = useState(false)
  const [selectedService, setSelectedService] = useState(null)
  const [selectedMachine, setSelectedMachine] = useState(null)
  const { error, handleError, clearError } = useErrorHandler()

  // Fetch health dashboard data from API
  const { data: healthDashboard, isLoading: healthLoading, error: healthError } = useQuery({
    queryKey: ['healthDashboard'],
    queryFn: () => getHealthDashboard(true),
    refetchInterval: 30000,
    onError: handleError,
  })

  // Fetch services and machines
  const { data: services = [], isLoading: servicesLoading, error: servicesError } = useQuery({
    queryKey: ['services'],
    queryFn: fetchServices,
    refetchInterval: 30000,
    onError: handleError,
  })

  const { data: machines = [], isLoading: machinesLoading, error: machinesError } = useQuery({
    queryKey: ['machines'],
    queryFn: fetchMachines,
    refetchInterval: 30000,
    onError: handleError,
  })

  const { data: problemFrequency } = useQuery({
    queryKey: ['problem-frequency'],
    queryFn: getProblemFrequency,
    refetchInterval: 60000,
    onError: handleError,
  })

  // Use real health overview data from API
  const healthOverview = healthDashboard ? {
    total_services: healthDashboard.total_services || 0,
    healthy: healthDashboard.healthy_services || 0,
    degraded: healthDashboard.degraded_services || 0,
    unhealthy: healthDashboard.unhealthy_services || 0,
    average_health_score: healthDashboard.overall_health_score || 0,
  } : {
    total_services: 0,
    healthy: 0,
    degraded: 0,
    unhealthy: 0,
    average_health_score: 0,
  }

  // Problem-frequency feed comes from /api/diagnostics/problems/frequency,
  // which returns List[ProblemFrequency] = [{problem_type, count, last_seen,
  // services_affected, severity}, ...]. Fan it out to one chart row per
  // (problem_type, service) so the bar chart's per-service filter works,
  // and derive a recent-problems list from the latest last_seen entries.
  const rawProblems = Array.isArray(problemFrequency) ? problemFrequency : []

  const problemFrequencyData = rawProblems.flatMap(p => {
    const services = Array.isArray(p.services_affected) && p.services_affected.length > 0
      ? p.services_affected
      : [null]
    return services.map(svc => ({
      problem_type: p.problem_type,
      service: svc,
      count: p.count,
      severity: p.severity || 'low',
      last_seen: p.last_seen,
    }))
  })

  const recentProblems = [...rawProblems]
    .sort((a, b) => new Date(b.last_seen || 0) - new Date(a.last_seen || 0))
    .slice(0, 5)
    .map((p, idx) => ({
      id: `${p.problem_type}-${idx}`,
      severity: p.severity || 'low',
      problem: p.problem_type,
      service: (p.services_affected && p.services_affected[0]) || '—',
      time: p.last_seen ? new Date(p.last_seen).toLocaleString() : '',
    }))

  // Get unique roles
  const roles = ['all', ...new Set(machines.map(m => m.role).filter(Boolean))]

  // Get service health data from dashboard
  const serviceHealthMap = new Map()
  if (healthDashboard && healthDashboard.services) {
    healthDashboard.services.forEach(service => {
      const key = `${service.service}-${service.machine}`
      serviceHealthMap.set(key, service)
    })
  }

  // Filter services using real health data
  const filteredServices = (healthDashboard?.services || []).filter(service => {
    const healthStatus = service.status || 'unknown'

    if (statusFilter !== 'all' && healthStatus !== statusFilter) {
      return false
    }

    if (machineFilter !== 'all' && service.machine !== machineFilter) {
      return false
    }

    // Role filter would need to check the machine's role
    if (roleFilter !== 'all') {
      const machine = machines.find(m => m.name === service.machine)
      if (!machine || machine.role !== roleFilter) {
        return false
      }
    }

    return true
  })

  const handleDiagnose = (service, machine) => {
    setSelectedService(service)
    setSelectedMachine(machine)
    setShowDiagnostics(true)
  }

  const handleViewDetails = (service, machine) => {
    setSelectedService(service)
    setSelectedMachine(machine)
    setShowDiagnostics(true)
  }

  const handleProblemClick = (problemData) => {
    const status = problemData?.status
    if (status === 'unhealthy' || status === 'degraded' || status === 'healthy') {
      setStatusFilter(status)
    } else {
      setStatusFilter('unhealthy')
    }
  }

  const getStatusIcon = (status) => {
    switch (status) {
      case 'healthy':
        return <CheckCircle className="w-5 h-5 text-green-600" />
      case 'degraded':
        return <AlertTriangle className="w-5 h-5 text-yellow-600" />
      case 'unhealthy':
        return <AlertTriangle className="w-5 h-5 text-red-600" />
      default:
        return <Activity className="w-5 h-5 text-gray-600" />
    }
  }

  const getSeverityColor = (severity) => {
    switch (severity) {
      case 'critical':
        return 'text-red-600'
      case 'high':
        return 'text-orange-600'
      case 'medium':
        return 'text-yellow-600'
      case 'low':
        return 'text-blue-600'
      default:
        return 'text-gray-600'
    }
  }

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <div className="bg-white border-b border-gray-200">
        <div className="container mx-auto px-4 py-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center space-x-3">
              <div className="p-2 bg-gradient-to-br from-green-500 to-blue-600 rounded-lg">
                <Heart className="w-8 h-8 text-white" />
              </div>
              <div>
                <h1 className="text-2xl font-bold text-gray-900">Health Dashboard</h1>
                <p className="text-sm text-gray-600">
                  Monitor service health and run diagnostics
                </p>
              </div>
            </div>

            <button
              onClick={() => setShowDiagnostics(true)}
              className="flex items-center space-x-2 px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors font-medium"
            >
              <Stethoscope className="w-5 h-5" />
              <span>Run Diagnostics</span>
            </button>
          </div>
        </div>
      </div>

      <div className="container mx-auto px-4 py-8">
        {/* Error Alert */}
        {error && <ErrorAlert error={error} onClose={clearError} />}

        {/* Overall Health Overview */}
        <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
          <div className="bg-white rounded-lg border border-gray-200 p-6">
            <div className="flex items-center justify-between mb-2">
              <div className="p-2 bg-blue-100 rounded-lg">
                <Server className="w-6 h-6 text-blue-600" />
              </div>
              <TrendingUp className="w-5 h-5 text-green-600" />
            </div>
            <div className="text-3xl font-bold text-gray-900 mb-1">
              {healthOverview.total_services}
            </div>
            <div className="text-sm text-gray-600">Total Services</div>
          </div>

          <div className="bg-green-50 rounded-lg border border-green-200 p-6">
            <div className="flex items-center justify-between mb-2">
              <div className="p-2 bg-green-100 rounded-lg">
                <CheckCircle className="w-6 h-6 text-green-600" />
              </div>
            </div>
            <div className="text-3xl font-bold text-green-700 mb-1">
              {healthOverview.healthy}
            </div>
            <div className="text-sm text-gray-600">Healthy</div>
          </div>

          <div className="bg-yellow-50 rounded-lg border border-yellow-200 p-6">
            <div className="flex items-center justify-between mb-2">
              <div className="p-2 bg-yellow-100 rounded-lg">
                <AlertTriangle className="w-6 h-6 text-yellow-600" />
              </div>
            </div>
            <div className="text-3xl font-bold text-yellow-700 mb-1">
              {healthOverview.degraded}
            </div>
            <div className="text-sm text-gray-600">Degraded</div>
          </div>

          <div className="bg-red-50 rounded-lg border border-red-200 p-6">
            <div className="flex items-center justify-between mb-2">
              <div className="p-2 bg-red-100 rounded-lg">
                <AlertTriangle className="w-6 h-6 text-red-600" />
              </div>
            </div>
            <div className="text-3xl font-bold text-red-700 mb-1">
              {healthOverview.unhealthy}
            </div>
            <div className="text-sm text-gray-600">Unhealthy</div>
          </div>
        </div>

        {/* Problem Frequency Chart */}
        <div className="mb-8">
          <ProblemFrequencyChart
            data={problemFrequencyData}
            onProblemClick={handleProblemClick}
          />
        </div>

        {/* Filters */}
        <div className="bg-white rounded-lg border border-gray-200 p-4 mb-6">
          <div className="flex items-center space-x-4">
            <div className="flex items-center space-x-2">
              <Filter className="w-5 h-5 text-gray-600" />
              <span className="text-sm font-medium text-gray-700">Filters:</span>
            </div>

            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="border border-gray-300 rounded-lg px-3 py-2 text-sm"
            >
              <option value="all">All Status</option>
              <option value="healthy">Healthy</option>
              <option value="degraded">Degraded</option>
              <option value="unhealthy">Unhealthy</option>
            </select>

            <select
              value={machineFilter}
              onChange={(e) => setMachineFilter(e.target.value)}
              className="border border-gray-300 rounded-lg px-3 py-2 text-sm"
            >
              <option value="all">All Machines</option>
              {machines.map(machine => (
                <option key={machine.name} value={machine.name}>
                  {machine.name}
                </option>
              ))}
            </select>

            <select
              value={roleFilter}
              onChange={(e) => setRoleFilter(e.target.value)}
              className="border border-gray-300 rounded-lg px-3 py-2 text-sm"
            >
              <option value="all">All Roles</option>
              {roles.filter(r => r !== 'all').map(role => (
                <option key={role} value={role}>
                  {role}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
          {/* Service Health Cards Grid */}
          <div className="lg:col-span-2">
            <h2 className="text-xl font-bold text-gray-900 mb-4">
              Service Health ({filteredServices.length})
            </h2>

            {healthLoading || servicesLoading ? (
              <div className="text-center py-12">
                <Activity className="w-12 h-12 text-blue-600 animate-spin mx-auto mb-4" />
                <p className="text-gray-600">Loading health data...</p>
              </div>
            ) : filteredServices.length === 0 ? (
              <div className="bg-white rounded-lg border border-gray-200 p-12 text-center">
                <CheckCircle className="w-16 h-16 text-gray-400 mx-auto mb-4" />
                <h3 className="text-lg font-semibold text-gray-900 mb-2">
                  No Services Found
                </h3>
                <p className="text-gray-600">
                  No services match the selected filters
                </p>
              </div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
                {filteredServices.map(healthService => {
                  const machine = machines.find(m => m.name === healthService.machine)
                  // Convert health service data to match ServiceHealthCard expectations
                  const serviceData = {
                    name: healthService.service,
                    machine_name: healthService.machine,
                    health_score: healthService.health_score,
                    status: healthService.status,
                    issues: healthService.issues || [],
                    uptime_seconds: healthService.uptime_seconds,
                    response_time_ms: healthService.response_time_ms,
                    last_checked: healthService.last_checked,
                  }
                  return (
                    <ServiceHealthCard
                      key={`${healthService.service}-${healthService.machine}`}
                      service={serviceData}
                      machine={machine}
                      onDiagnose={handleDiagnose}
                      onViewDetails={handleViewDetails}
                    />
                  )
                })}
              </div>
            )}
          </div>
        </div>

        {/* Recent Problems Timeline */}
        <div className="bg-white rounded-lg border border-gray-200 p-6">
          <div className="flex items-center space-x-3 mb-4">
            <Clock className="w-6 h-6 text-blue-600" />
            <h2 className="text-xl font-bold text-gray-900">
              Recent Problems
            </h2>
          </div>

          <div className="space-y-3">
            {recentProblems.map(problem => (
              <div
                key={problem.id}
                className="flex items-center justify-between p-3 bg-gray-50 rounded-lg border border-gray-200 hover:bg-gray-100 transition-colors cursor-pointer"
              >
                <div className="flex items-center space-x-3 flex-1">
                  {getStatusIcon(problem.severity === 'critical' ? 'unhealthy' : problem.severity === 'high' ? 'degraded' : 'healthy')}
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center space-x-2 mb-1">
                      <span className="font-medium text-gray-900">{problem.service}</span>
                      <span className={clsx('text-xs font-semibold', getSeverityColor(problem.severity))}>
                        {problem.severity.toUpperCase()}
                      </span>
                    </div>
                    <p className="text-sm text-gray-700">{problem.problem}</p>
                  </div>
                </div>
                <span className="text-xs text-gray-500 ml-4 flex-shrink-0">
                  {problem.time}
                </span>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Diagnostics Panel */}
      {showDiagnostics && (
        <DiagnosticsPanel
          serviceName={selectedService?.name}
          machineName={selectedMachine?.name}
          onClose={() => {
            setShowDiagnostics(false)
            setSelectedService(null)
            setSelectedMachine(null)
          }}
        />
      )}
    </div>
  )
}

export default HealthDashboard
