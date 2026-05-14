import React, { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Stethoscope,
  Play,
  Loader2,
  AlertTriangle,
  CheckCircle,
  Info,
  Wrench,
  X,
  TrendingUp,
  Activity
} from 'lucide-react'
import clsx from 'clsx'
import { runDiagnostics, applyFix, fetchServices, fetchMachines } from '../../api/client'
import { useErrorHandler } from '../../hooks/useErrorHandler'
import ErrorAlert from '../ErrorAlert'

function DiagnosticsPanel({ serviceName, machineName, onClose }) {
  const [selectedService, setSelectedService] = useState(serviceName || '')
  const [selectedMachine, setSelectedMachine] = useState(machineName || '')
  const [diagnosticResults, setDiagnosticResults] = useState(null)
  const queryClient = useQueryClient()
  const { error, handleError, clearError } = useErrorHandler()

  // Determine if we need to show selectors (only if service/machine not provided)
  const showSelectors = !serviceName || !machineName

  // Fetch services and machines for dropdowns (only if needed). Use the
  // authenticated client — raw fetch bypasses the Bearer interceptor.
  const { data: servicesData, isLoading: servicesLoading, error: servicesError } = useQuery({
    queryKey: ['services'],
    queryFn: fetchServices,
    retry: 2,
    retryDelay: 1000,
    enabled: showSelectors,
  })

  const { data: machinesData, isLoading: machinesLoading, error: machinesError } = useQuery({
    queryKey: ['machines'],
    queryFn: fetchMachines,
    retry: 2,
    retryDelay: 1000,
    enabled: showSelectors,
  })

  const services = servicesData || []
  const machines = machinesData || []

  // Run diagnostics mutation
  const diagnosticsMutation = useMutation({
    mutationFn: ({ service, machine }) => runDiagnostics(service, machine),
    onSuccess: (data) => {
      setDiagnosticResults(data)
      queryClient.invalidateQueries(['service-health'])
      clearError()
    },
    onError: (err) => {
      handleError(err)
    },
  })

  // Apply fix mutation
  const applyFixMutation = useMutation({
    mutationFn: ({ solutionId, service, machine }) =>
      applyFix(solutionId, service, machine),
    onSuccess: () => {
      queryClient.invalidateQueries(['diagnostics'])
      queryClient.invalidateQueries(['service-health'])
      clearError()
      // Re-run diagnostics to update results
      if (selectedService && selectedMachine) {
        diagnosticsMutation.mutate({
          service: selectedService,
          machine: selectedMachine
        })
      }
    },
    onError: (err) => {
      handleError(err)
    },
  })

  const handleRunDiagnostics = () => {
    if (!selectedService || !selectedMachine) {
      alert('Please select both a service and a machine')
      return
    }

    diagnosticsMutation.mutate({
      service: selectedService,
      machine: selectedMachine,
    })
  }

  const handleApplyFix = (solution) => {
    if (window.confirm(`Apply fix: ${solution.title}?\n\n${solution.description}`)) {
      applyFixMutation.mutate({
        solutionId: solution.id,
        service: selectedService,
        machine: selectedMachine,
      })
    }
  }

  const getSeverityColor = (severity) => {
    switch (severity) {
      case 'critical':
        return 'bg-red-100 text-red-800 border-red-300'
      case 'high':
        return 'bg-orange-100 text-orange-800 border-orange-300'
      case 'medium':
        return 'bg-yellow-100 text-yellow-800 border-yellow-300'
      case 'low':
        return 'bg-blue-100 text-blue-800 border-blue-300'
      default:
        return 'bg-gray-100 text-gray-800 border-gray-300'
    }
  }

  const getHealthScoreColor = (score) => {
    if (score >= 80) return 'text-green-600'
    if (score >= 60) return 'text-yellow-600'
    if (score >= 40) return 'text-orange-600'
    return 'text-red-600'
  }

  const getObservationIcon = (type) => {
    switch (type) {
      case 'success':
        return <CheckCircle className="w-5 h-5 text-green-600" />
      case 'warning':
        return <AlertTriangle className="w-5 h-5 text-yellow-600" />
      case 'info':
        return <Info className="w-5 h-5 text-blue-600" />
      default:
        return <Activity className="w-5 h-5 text-gray-600" />
    }
  }

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
      <div className="bg-white rounded-lg shadow-2xl w-full max-w-5xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-gray-200">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-blue-100 rounded-lg">
              <Stethoscope className="w-6 h-6 text-blue-600" />
            </div>
            <div>
              <h2 className="text-xl font-bold text-gray-900">Service Diagnostics</h2>
              <p className="text-sm text-gray-600">
                Run comprehensive diagnostics and apply automated fixes
              </p>
            </div>
          </div>

          <button
            onClick={onClose}
            className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
          >
            <X className="w-5 h-5 text-gray-500" />
          </button>
        </div>

        {/* Selectors - only show if service/machine not provided */}
        {showSelectors ? (
          <div className="p-6 border-b border-gray-200 bg-gray-50">
            {error && <ErrorAlert error={error} onClose={clearError} />}
            {(servicesError || machinesError) && (
              <div className="mb-4 p-4 bg-red-50 border border-red-200 rounded-lg">
                <p className="text-sm text-red-800">
                  {servicesError ? `Error loading services: ${servicesError.message}` : ''}
                  {servicesError && machinesError ? ' | ' : ''}
                  {machinesError ? `Error loading machines: ${machinesError.message}` : ''}
                </p>
              </div>
            )}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Service
                </label>
                <select
                  value={selectedService}
                  onChange={(e) => setSelectedService(e.target.value)}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                >
                  <option value="">Select a service...</option>
                  {services?.map((service) => (
                    <option key={service.name} value={service.name}>
                      {service.name}
                    </option>
                  ))}
                </select>
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Machine
                </label>
                <select
                  value={selectedMachine}
                  onChange={(e) => setSelectedMachine(e.target.value)}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                >
                  <option value="">Select a machine...</option>
                  {machines?.map((machine) => (
                    <option key={machine.name} value={machine.name}>
                      {machine.name}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <button
              onClick={handleRunDiagnostics}
              disabled={!selectedService || !selectedMachine || diagnosticsMutation.isPending}
              className={clsx(
                'mt-4 w-full flex items-center justify-center space-x-2 px-6 py-3 rounded-lg font-medium transition-colors',
                {
                  'bg-blue-600 text-white hover:bg-blue-700': selectedService && selectedMachine && !diagnosticsMutation.isPending,
                  'bg-gray-300 text-gray-500 cursor-not-allowed': !selectedService || !selectedMachine || diagnosticsMutation.isPending,
                }
              )}
            >
              {diagnosticsMutation.isPending ? (
                <>
                  <Loader2 className="w-5 h-5 animate-spin" />
                  <span>Running Diagnostics...</span>
                </>
              ) : (
                <>
                  <Play className="w-5 h-5" />
                  <span>Run Diagnostics</span>
                </>
              )}
            </button>
          </div>
        ) : (
          <div className="p-6 border-b border-gray-200 bg-linear-to-r from-blue-50 to-purple-50">
            {error && <ErrorAlert error={error} onClose={clearError} />}
            <div className="flex items-center justify-between">
              <div>
                <h3 className="text-lg font-semibold text-gray-900">{selectedService}</h3>
                <p className="text-sm text-gray-600">on {selectedMachine}</p>
              </div>
              <button
                onClick={handleRunDiagnostics}
                disabled={diagnosticsMutation.isPending}
                className={clsx(
                  'flex items-center space-x-2 px-6 py-3 rounded-lg font-medium transition-colors',
                  {
                    'bg-blue-600 text-white hover:bg-blue-700': !diagnosticsMutation.isPending,
                    'bg-gray-400 text-white cursor-not-allowed': diagnosticsMutation.isPending,
                  }
                )}
              >
                {diagnosticsMutation.isPending ? (
                  <>
                    <Loader2 className="w-5 h-5 animate-spin" />
                    <span>Running...</span>
                  </>
                ) : (
                  <>
                    <Play className="w-5 h-5" />
                    <span>Run Diagnostics</span>
                  </>
                )}
              </button>
            </div>
          </div>
        )}

        {/* Results */}
        <div className="flex-1 overflow-y-auto p-6">
          {diagnosticResults ? (
            <div className="space-y-6">
              {/* Health Score */}
              <div className="bg-linear-to-br from-blue-50 to-purple-50 border border-blue-200 rounded-lg p-6">
                <div className="flex items-center justify-between">
                  <div>
                    <h3 className="text-lg font-semibold text-gray-900 mb-1">
                      Health Score
                    </h3>
                    <p className="text-sm text-gray-600">
                      Overall service health assessment
                    </p>
                  </div>
                  <div className="flex items-center space-x-4">
                    <div className="relative w-24 h-24">
                      <svg className="transform -rotate-90 w-24 h-24">
                        <circle
                          cx="48"
                          cy="48"
                          r="40"
                          stroke="#e5e7eb"
                          strokeWidth="8"
                          fill="none"
                        />
                        <circle
                          cx="48"
                          cy="48"
                          r="40"
                          stroke="currentColor"
                          strokeWidth="8"
                          fill="none"
                          strokeDasharray={`${2 * Math.PI * 40}`}
                          strokeDashoffset={`${2 * Math.PI * 40 * (1 - diagnosticResults.health_score / 100)}`}
                          className={getHealthScoreColor(diagnosticResults.health_score)}
                          strokeLinecap="round"
                        />
                      </svg>
                      <div className="absolute inset-0 flex items-center justify-center">
                        <span className={clsx('text-2xl font-bold', getHealthScoreColor(diagnosticResults.health_score))}>
                          {diagnosticResults.health_score}
                        </span>
                      </div>
                    </div>
                    <TrendingUp className={clsx('w-8 h-8', getHealthScoreColor(diagnosticResults.health_score))} />
                  </div>
                </div>
              </div>

              {/* Observations */}
              {diagnosticResults.observations && diagnosticResults.observations.length > 0 && (
                <div>
                  <h3 className="text-lg font-semibold text-gray-900 mb-3">
                    Observations ({diagnosticResults.observations.length})
                  </h3>
                  <div className="space-y-2">
                    {diagnosticResults.observations.map((obs, idx) => (
                      <div
                        key={idx}
                        className="flex items-start space-x-3 p-4 bg-gray-50 border border-gray-200 rounded-lg"
                      >
                        {getObservationIcon(obs.type)}
                        <div className="flex-1">
                          <h4 className="font-medium text-gray-900">{obs.name}</h4>
                          <p className="text-sm text-gray-600 mt-1">{obs.message}</p>
                          {obs.details && (
                            <pre className="text-xs text-gray-500 mt-2 bg-white p-2 rounded border border-gray-200 overflow-x-auto">
                              {JSON.stringify(obs.details, null, 2)}
                            </pre>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Problems */}
              {diagnosticResults.problems && diagnosticResults.problems.length > 0 && (
                <div>
                  <h3 className="text-lg font-semibold text-gray-900 mb-3">
                    Problems ({diagnosticResults.problems.length})
                  </h3>
                  <div className="space-y-3">
                    {diagnosticResults.problems.map((problem, idx) => (
                      <div
                        key={idx}
                        className="border border-gray-200 rounded-lg p-4 bg-white"
                      >
                        <div className="flex items-start justify-between mb-3">
                          <div className="flex items-start space-x-3 flex-1">
                            <AlertTriangle className="w-5 h-5 text-orange-600 shrink-0 mt-0.5" />
                            <div className="flex-1">
                              <div className="flex items-center space-x-2 mb-1">
                                <h4 className="font-semibold text-gray-900">
                                  {problem.name}
                                </h4>
                                <span className={clsx(
                                  'px-2 py-1 text-xs font-bold rounded border',
                                  getSeverityColor(problem.severity)
                                )}>
                                  {problem.severity.toUpperCase()}
                                </span>
                              </div>
                              <p className="text-sm text-gray-700 mb-2">
                                {problem.description}
                              </p>
                              {problem.root_cause && (
                                <p className="text-sm text-gray-600">
                                  <span className="font-medium">Root cause:</span> {problem.root_cause}
                                </p>
                              )}
                            </div>
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Solutions */}
              {diagnosticResults.solutions && diagnosticResults.solutions.length > 0 && (
                <div>
                  <h3 className="text-lg font-semibold text-gray-900 mb-3">
                    Recommended Solutions ({diagnosticResults.solutions.length})
                  </h3>
                  <div className="space-y-3">
                    {diagnosticResults.solutions.map((solution, idx) => (
                      <div
                        key={idx}
                        className="border border-green-200 bg-green-50 rounded-lg p-4"
                      >
                        <div className="flex items-start justify-between">
                          <div className="flex items-start space-x-3 flex-1">
                            <Wrench className="w-5 h-5 text-green-600 shrink-0 mt-0.5" />
                            <div className="flex-1">
                              <h4 className="font-semibold text-gray-900 mb-1">
                                {solution.title}
                              </h4>
                              <p className="text-sm text-gray-700 mb-3">
                                {solution.description}
                              </p>
                              {solution.steps && solution.steps.length > 0 && (
                                <div className="text-sm text-gray-600 mb-3">
                                  <p className="font-medium mb-1">Steps:</p>
                                  <ol className="list-decimal list-inside space-y-1">
                                    {solution.steps.map((step, stepIdx) => (
                                      <li key={stepIdx}>{step}</li>
                                    ))}
                                  </ol>
                                </div>
                              )}
                            </div>
                          </div>
                          {solution.auto_apply && (
                            <button
                              onClick={() => handleApplyFix(solution)}
                              disabled={applyFixMutation.isPending}
                              className="ml-4 flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors disabled:bg-gray-400 disabled:cursor-not-allowed shrink-0"
                            >
                              {applyFixMutation.isPending ? (
                                <Loader2 className="w-4 h-4 animate-spin" />
                              ) : (
                                <Wrench className="w-4 h-4" />
                              )}
                              <span>Apply Fix</span>
                            </button>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Empty state */}
              {(!diagnosticResults.problems || diagnosticResults.problems.length === 0) &&
               (!diagnosticResults.observations || diagnosticResults.observations.length === 0) && (
                <div className="text-center py-12">
                  <CheckCircle className="w-16 h-16 text-green-600 mx-auto mb-4" />
                  <h3 className="text-lg font-semibold text-gray-900 mb-2">
                    All Systems Healthy
                  </h3>
                  <p className="text-gray-600">
                    No problems detected during diagnostics
                  </p>
                </div>
              )}
            </div>
          ) : (
            <div className="text-center py-12">
              <Stethoscope className="w-16 h-16 text-gray-400 mx-auto mb-4" />
              <h3 className="text-lg font-semibold text-gray-900 mb-2">
                Ready to Run Diagnostics
              </h3>
              <p className="text-gray-600">
                Select a service and machine, then click "Run Diagnostics" to begin
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

export default DiagnosticsPanel
