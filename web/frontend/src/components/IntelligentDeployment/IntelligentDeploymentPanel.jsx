import React, { useState, useEffect } from 'react'
import { X, Loader2, CheckCircle, XCircle, Sparkles, Play, RotateCcw } from 'lucide-react'
import clsx from 'clsx'
import DeploymentPhases from './DeploymentPhases'
import { ObservationList } from './ObservationCard'
import { ProblemList } from './ProblemCard'
import { SolutionList } from './SolutionCard'
import DeploymentOptions from './DeploymentOptions'
import { useWebSocket } from '../../hooks/useWebSocket'
import { intelligentDeploy, getDeploymentPhases, getDeploymentResult, buildAuthedWsUrl } from '../../api/client'

function IntelligentDeploymentPanel({ service, onClose }) {
  const [currentPhase, setCurrentPhase] = useState(1)
  const [completedPhases, setCompletedPhases] = useState([])
  const [observations, setObservations] = useState([])
  const [problems, setProblems] = useState([])
  const [solutions, setSolutions] = useState([])
  const [deploymentOptions, setDeploymentOptions] = useState({
    autoHealing: true,
    dryRun: false,
    verboseLogging: false,
    stopOnFirstError: false,
  })
  // 'idle' | 'running' | 'completed' | 'failed' — no pause/cancel since the
  // backend deployment runs as a single async pipeline with no cooperative
  // checkpoint support today. Closing the dialog while running will leave the
  // server-side deployment running to completion.
  const [deploymentStatus, setDeploymentStatus] = useState('idle')
  const [activeTab, setActiveTab] = useState('overview')
  const [deploymentId, setDeploymentId] = useState(null)
  const [error, setError] = useState(null)

  // Authenticated WebSocket URL for real-time deployment updates.
  const wsUrl = deploymentId ? buildAuthedWsUrl(`/api/deployment/ws/${deploymentId}`) : null
  const { status: wsStatus, lastMessage } = useWebSocket(wsUrl)

  useEffect(() => {
    if (lastMessage) {
      try {
        const data = JSON.parse(lastMessage.data)
        handleWebSocketMessage(data)
      } catch (error) {
        console.error('Failed to parse WebSocket message:', error)
      }
    }
  }, [lastMessage])

  const handleWebSocketMessage = (data) => {
    switch (data.type) {
      case 'phase_started':
        setCurrentPhase(data.phase)
        setDeploymentStatus('running')
        break

      case 'phase_completed':
        setCompletedPhases((prev) => [...prev, data.phase])
        break

      case 'observation':
        setObservations((prev) => [...prev, {
          name: data.name,
          status: data.status,
          message: data.message,
          details: data.details,
          timestamp: new Date().toISOString(),
        }])
        break

      case 'problem_detected':
        setProblems((prev) => [...prev, {
          name: data.name,
          severity: data.severity,
          description: data.description,
          rootCause: data.rootCause,
          recommendedSolution: data.recommendedSolution,
          timestamp: new Date().toISOString(),
          autoFixAvailable: data.autoFixAvailable,
        }])
        break

      case 'solution_started':
        setSolutions((prev) => [...prev, {
          name: data.name,
          status: 'in_progress',
          steps: data.steps || [],
          currentStep: 0,
          timestamp: new Date().toISOString(),
        }])
        break

      case 'solution_progress':
        setSolutions((prev) =>
          prev.map((sol, idx) =>
            idx === prev.length - 1
              ? { ...sol, currentStep: data.currentStep }
              : sol
          )
        )
        break

      case 'solution_completed':
        setSolutions((prev) =>
          prev.map((sol, idx) =>
            idx === prev.length - 1
              ? { ...sol, status: 'success' }
              : sol
          )
        )
        break

      case 'solution_failed':
        setSolutions((prev) =>
          prev.map((sol, idx) =>
            idx === prev.length - 1
              ? { ...sol, status: 'failed', error: data.error }
              : sol
          )
        )
        break

      case 'deployment_completed':
        setDeploymentStatus('completed')
        setCompletedPhases([1, 2, 3, 4])
        break

      case 'deployment_failed':
        setDeploymentStatus('failed')
        break
    }
  }

  const handleStartDeployment = async () => {
    if (!service || !service.current_host) {
      setError('Service or machine not specified')
      return
    }

    setDeploymentStatus('running')
    setCurrentPhase(1)
    setCompletedPhases([])
    setObservations([])
    setProblems([])
    setSolutions([])
    setError(null)

    try {
      // Start intelligent deployment via API
      const result = await intelligentDeploy(service.name, service.current_host, {
        autoHeal: deploymentOptions.autoHealing,
        dryRun: deploymentOptions.dryRun
      })

      setDeploymentId(result.deployment_id)

      // Process phases from result
      if (result.phases) {
        result.phases.forEach(phase => {
          if (phase.status === 'completed') {
            setCompletedPhases(prev => [...prev, phase.name])
          }
        })
      }

      // Update final status
      if (result.success) {
        setDeploymentStatus('completed')
      } else {
        setDeploymentStatus('failed')
        setError(result.error || 'Deployment failed')
      }

    } catch (err) {
      console.error('Deployment failed:', err)
      setDeploymentStatus('failed')
      setError(err.response?.data?.detail || err.message || 'Deployment failed')
    }
  }

  const handleRetryDeployment = () => {
    handleStartDeployment()
  }

  // Problem actions are server-side concerns (auto-fix, skip, manual) — the
  // backend doesn't yet expose endpoints for them, so we surface a placeholder
  // alert instead of silently swallowing the click.
  const handleProblemAction = (_problem, _action) => {
    alert('Problem actions are not implemented yet. The backend will need to expose auto-fix/skip endpoints first.')
  }

  const tabs = [
    { id: 'overview', label: 'Overview', icon: Sparkles },
    { id: 'observations', label: `Observations (${observations.length})`, badge: observations.length },
    { id: 'problems', label: `Problems (${problems.length})`, badge: problems.length },
    { id: 'solutions', label: `Solutions (${solutions.length})`, badge: solutions.length },
    { id: 'options', label: 'Options' },
  ]

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
      <div className="bg-white rounded-lg shadow-2xl w-full max-w-6xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-gray-200">
          <div className="flex items-center space-x-3">
            <div className="p-2 bg-linear-to-br from-blue-500 to-purple-600 rounded-lg">
              <Sparkles className="w-6 h-6 text-white" />
            </div>
            <div>
              <h2 className="text-xl font-bold text-gray-900">Intelligent Deployment</h2>
              <p className="text-sm text-gray-600">
                {service ? `Deploying ${service.name}` : 'AI-powered deployment with auto-healing'}
              </p>
            </div>
          </div>

          <div className="flex items-center space-x-3">
            {/* Status indicator */}
            <div className="flex items-center space-x-2">
              {deploymentStatus === 'running' && (
                <>
                  <Loader2 className="w-5 h-5 text-blue-600 animate-spin" />
                  <span className="text-sm font-medium text-blue-600">Running</span>
                </>
              )}
              {deploymentStatus === 'completed' && (
                <>
                  <CheckCircle className="w-5 h-5 text-green-600" />
                  <span className="text-sm font-medium text-green-600">Completed</span>
                </>
              )}
              {deploymentStatus === 'failed' && (
                <>
                  <XCircle className="w-5 h-5 text-red-600" />
                  <span className="text-sm font-medium text-red-600">Failed</span>
                </>
              )}
            </div>

            <button
              onClick={onClose}
              className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
            >
              <X className="w-5 h-5 text-gray-500" />
            </button>
          </div>
        </div>

        {/* Tabs */}
        <div className="border-b border-gray-200">
          <div className="flex space-x-1 px-6">
            {tabs.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={clsx(
                  'px-4 py-3 text-sm font-medium transition-colors relative',
                  {
                    'text-blue-600 border-b-2 border-blue-600': activeTab === tab.id,
                    'text-gray-600 hover:text-gray-900': activeTab !== tab.id,
                  }
                )}
              >
                <span className="flex items-center space-x-2">
                  {tab.icon && <tab.icon className="w-4 h-4" />}
                  <span>{tab.label}</span>
                  {tab.badge > 0 && (
                    <span className="px-2 py-0.5 bg-blue-100 text-blue-700 text-xs font-bold rounded-full">
                      {tab.badge}
                    </span>
                  )}
                </span>
              </button>
            ))}
          </div>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6">
          {activeTab === 'overview' && (
            <div className="space-y-6">
              <DeploymentPhases
                currentPhase={currentPhase}
                completedPhases={completedPhases}
              />

              {/* Quick stats */}
              <div className="grid grid-cols-3 gap-4">
                <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
                  <div className="text-2xl font-bold text-blue-700">{observations.length}</div>
                  <div className="text-sm text-gray-600">Observations</div>
                </div>
                <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
                  <div className="text-2xl font-bold text-yellow-700">{problems.length}</div>
                  <div className="text-sm text-gray-600">Problems</div>
                </div>
                <div className="bg-green-50 border border-green-200 rounded-lg p-4">
                  <div className="text-2xl font-bold text-green-700">{solutions.length}</div>
                  <div className="text-sm text-gray-600">Solutions</div>
                </div>
              </div>
            </div>
          )}

          {activeTab === 'observations' && (
            <ObservationList observations={observations} />
          )}

          {activeTab === 'problems' && (
            <ProblemList problems={problems} onAction={handleProblemAction} />
          )}

          {activeTab === 'solutions' && (
            <SolutionList solutions={solutions} />
          )}

          {activeTab === 'options' && (
            <DeploymentOptions
              options={deploymentOptions}
              onChange={setDeploymentOptions}
            />
          )}
        </div>

        {/* Footer Actions */}
        <div className="border-t border-gray-200 p-6 bg-gray-50">
          <div className="flex items-center justify-between">
            <div className="text-sm text-gray-600">
              {deploymentStatus === 'idle' && 'Ready to start deployment'}
              {deploymentStatus === 'running' && `Phase ${currentPhase} of 4 in progress... (deployment will continue if you close this dialog)`}
              {deploymentStatus === 'completed' && 'Deployment completed successfully!'}
              {deploymentStatus === 'failed' && 'Deployment failed. Check logs for details.'}
            </div>

            <div className="flex items-center space-x-3">
              {deploymentStatus === 'idle' && (
                <button
                  onClick={handleStartDeployment}
                  className="flex items-center space-x-2 px-6 py-3 bg-linear-to-r from-blue-600 to-purple-600 text-white rounded-lg hover:from-blue-700 hover:to-purple-700 transition-all shadow-lg hover:shadow-xl font-medium"
                >
                  <Play className="w-5 h-5" />
                  <span>Start Intelligent Deployment</span>
                </button>
              )}

              {(deploymentStatus === 'completed' || deploymentStatus === 'failed') && (
                <>
                  <button
                    onClick={handleRetryDeployment}
                    className="flex items-center space-x-2 px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
                  >
                    <RotateCcw className="w-5 h-5" />
                    <span>Deploy Again</span>
                  </button>
                  <button
                    onClick={onClose}
                    className="px-4 py-2 border border-gray-300 text-gray-700 rounded-lg hover:bg-gray-100 transition-colors"
                  >
                    Close
                  </button>
                </>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

export default IntelligentDeploymentPanel
