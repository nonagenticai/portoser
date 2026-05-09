import React, { useEffect, useRef, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { executeDeployment } from '../api/client'
import { Rocket, X, AlertCircle, CheckCircle, Loader2 } from 'lucide-react'
import Tooltip from './Tooltip'
import clsx from 'clsx'

function DeploymentPanel({ pendingMoves, onClearMoves, deploymentLogs }) {
  const [isDeploying, setIsDeploying] = useState(false)
  const queryClient = useQueryClient()
  const clearTimerRef = useRef(null)

  // Cancel any pending "deployed!" -> "idle" timer if the component unmounts
  // mid-flight. Otherwise React warns about state updates on an unmounted
  // component and the closure leaks until the timer fires.
  useEffect(() => {
    return () => {
      if (clearTimerRef.current) {
        clearTimeout(clearTimerRef.current)
        clearTimerRef.current = null
      }
    }
  }, [])

  const deployMutation = useMutation({
    mutationFn: executeDeployment,
    onMutate: () => {
      setIsDeploying(true)
    },
    onSuccess: () => {
      queryClient.invalidateQueries(['machines'])
      queryClient.invalidateQueries(['services'])
      clearTimerRef.current = setTimeout(() => {
        setIsDeploying(false)
        clearTimerRef.current = null
      }, 2000)
    },
    onError: () => {
      setIsDeploying(false)
    },
  })

  const handleDeploy = () => {
    if (pendingMoves.length === 0) return

    deployMutation.mutate({ moves: pendingMoves })
  }

  if (pendingMoves.length === 0 && !isDeploying) {
    return null
  }

  return (
    <div className="fixed bottom-0 right-0 left-0 bg-white border-t-2 border-gray-200 shadow-lg">
      <div className="container mx-auto px-4 py-4">
        <div className="flex items-start justify-between">
          <div className="flex-1">
            <div className="flex items-center space-x-2 mb-2">
              <Rocket className="w-5 h-5 text-primary" />
              <Tooltip content="Review all pending service movements before deploying. Each change will be executed sequentially using the portoser CLI.">
                <h3 className="font-semibold text-gray-900 cursor-help">
                  Deployment Plan ({pendingMoves.length} {pendingMoves.length === 1 ? 'change' : 'changes'})
                </h3>
              </Tooltip>
            </div>

            <div className="space-y-1 max-h-32 overflow-y-auto">
              {pendingMoves.map((move, idx) => (
                <div
                  key={idx}
                  className="flex items-center space-x-2 text-sm text-gray-600"
                >
                  <div className="w-2 h-2 bg-warning rounded-full"></div>
                  <span>
                    Move <strong>{move.service_name}</strong> from{' '}
                    <strong>{move.from_machine}</strong> to{' '}
                    <strong className="text-primary">{move.to_machine}</strong>
                  </span>
                </div>
              ))}
            </div>

            {deploymentLogs.length > 0 && (
              <div className="mt-4 bg-gray-900 text-gray-100 rounded-lg p-3 max-h-40 overflow-y-auto font-mono text-xs">
                {deploymentLogs.map((log, idx) => (
                  <div key={idx} className="mb-1">{log}</div>
                ))}
              </div>
            )}
          </div>

          <div className="flex items-center space-x-3 ml-6">
            {!isDeploying && (
              <>
                <Tooltip content="Clear all pending changes and start over">
                  <button
                    onClick={onClearMoves}
                    className="px-4 py-2 text-gray-600 hover:text-gray-900 transition-colors"
                  >
                    Clear
                  </button>
                </Tooltip>

                <Tooltip content="Execute all pending service movements. This will run 'portoser deploy' for each change and stream live progress.">
                  <button
                    onClick={handleDeploy}
                    disabled={pendingMoves.length === 0}
                    className={clsx(
                      'flex items-center space-x-2 px-6 py-3 rounded-lg font-medium transition-all',
                      'bg-primary text-white hover:bg-blue-600 shadow-lg hover:shadow-xl',
                      'disabled:opacity-50 disabled:cursor-not-allowed'
                    )}
                  >
                    <Rocket className="w-5 h-5" />
                    <span>Deploy Changes</span>
                  </button>
                </Tooltip>
              </>
            )}

            {isDeploying && (
              <div className="flex items-center space-x-3">
                {deployMutation.isSuccess ? (
                  <>
                    <CheckCircle className="w-5 h-5 text-success" />
                    <span className="text-success font-medium">Deployed!</span>
                  </>
                ) : deployMutation.isError ? (
                  <>
                    <AlertCircle className="w-5 h-5 text-danger" />
                    <span className="text-danger font-medium">Failed</span>
                  </>
                ) : (
                  <>
                    <Loader2 className="w-5 h-5 text-primary animate-spin" />
                    <span className="text-primary font-medium">Deploying...</span>
                  </>
                )}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

export default DeploymentPanel
