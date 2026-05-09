import React, { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Code, Plus, Activity, Database, Shield } from 'lucide-react'
import MCPToolList from './MCPToolList'
import MCPToolEditor from './MCPToolEditor'
import MCPConfig from './MCPConfig'
import { getMCPStatus } from '../../api/client'

function MCPDashboard() {
  const [showEditor, setShowEditor] = useState(false)
  const [showConfig, setShowConfig] = useState(false)
  const [editingTool, setEditingTool] = useState(null)
  const [viewingTool, setViewingTool] = useState(null)

  const { data: statusData } = useQuery({
    queryKey: ['mcp-status'],
    queryFn: getMCPStatus,
    refetchInterval: 10000,
  })

  const handleCreateTool = () => {
    setEditingTool(null)
    setShowEditor(true)
  }

  const handleEditTool = (tool) => {
    setEditingTool(tool)
    setShowEditor(true)
  }

  const handleViewTool = (tool) => {
    setViewingTool(tool)
  }

  const handleCloseEditor = () => {
    setShowEditor(false)
    setEditingTool(null)
  }

  const handleEditorSuccess = () => {
    handleCloseEditor()
  }

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <div className="bg-white border-b border-gray-200">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
          <div className="flex items-center justify-between">
            <div className="flex items-center space-x-4">
              <div className="p-3 bg-blue-100 rounded-lg">
                <Code className="w-8 h-8 text-blue-600" />
              </div>
              <div>
                <h1 className="text-2xl font-bold text-gray-900">MCP Tools Dashboard</h1>
                <p className="text-sm text-gray-600 mt-1">
                  Manage Model Context Protocol tools and integrations
                </p>
              </div>
            </div>

            <div className="flex items-center space-x-3">
              <button
                onClick={() => setShowConfig(!showConfig)}
                className="flex items-center space-x-2 px-4 py-2 text-gray-700 bg-white border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors"
              >
                <Shield className="w-4 h-4" />
                <span>Configuration</span>
              </button>
              <button
                onClick={handleCreateTool}
                className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
              >
                <Plus className="w-4 h-4" />
                <span>Create Tool</span>
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* Stats */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
          <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium text-gray-600">Server Status</p>
                <p className="text-2xl font-bold text-gray-900 mt-2">
                  {statusData?.status === 'running' ? 'Running' : 'Offline'}
                </p>
              </div>
              <Activity className={`w-8 h-8 ${statusData?.status === 'running' ? 'text-green-600' : 'text-gray-400'}`} />
            </div>
          </div>

          <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium text-gray-600">Protocol Version</p>
                <p className="text-2xl font-bold text-gray-900 mt-2">
                  {statusData?.version || 'N/A'}
                </p>
              </div>
              <Code className="w-8 h-8 text-blue-600" />
            </div>
          </div>

          <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-sm font-medium text-gray-600">Transport</p>
                <p className="text-2xl font-bold text-gray-900 mt-2">
                  {statusData?.transport?.toUpperCase() || 'SSE'}
                </p>
              </div>
              <Database className="w-8 h-8 text-purple-600" />
            </div>
          </div>
        </div>

        {/* Config Panel */}
        {showConfig && (
          <div className="mb-8">
            <MCPConfig onClose={() => setShowConfig(false)} />
          </div>
        )}

        {/* Tools List */}
        <div className="bg-white rounded-lg shadow-sm p-6 border border-gray-200">
          <h2 className="text-lg font-semibold text-gray-900 mb-6">Available Tools</h2>
          <MCPToolList onEditTool={handleEditTool} onViewTool={handleViewTool} />
        </div>
      </div>

      {/* Tool Editor Modal */}
      {showEditor && (
        <MCPToolEditor
          tool={editingTool}
          onClose={handleCloseEditor}
          onSuccess={handleEditorSuccess}
        />
      )}

      {/* Tool View Modal */}
      {viewingTool && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
          <div className="bg-white rounded-lg shadow-xl max-w-3xl w-full max-h-[90vh] overflow-hidden">
            <div className="flex items-center justify-between p-6 border-b border-gray-200">
              <h2 className="text-xl font-bold text-gray-900">{viewingTool.name}</h2>
              <button
                onClick={() => setViewingTool(null)}
                className="p-2 text-gray-400 hover:text-gray-600 rounded-lg hover:bg-gray-100 transition-colors"
              >
                ×
              </button>
            </div>
            <div className="p-6 overflow-y-auto max-h-[calc(90vh-140px)]">
              <div className="space-y-4">
                <div>
                  <h3 className="text-sm font-medium text-gray-700 mb-2">Description</h3>
                  <p className="text-gray-900">{viewingTool.description}</p>
                </div>
                {viewingTool.inputSchema && (
                  <div>
                    <h3 className="text-sm font-medium text-gray-700 mb-2">Input Schema</h3>
                    <pre className="bg-gray-50 border border-gray-200 rounded-lg p-4 text-sm overflow-x-auto">
                      {JSON.stringify(viewingTool.inputSchema, null, 2)}
                    </pre>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

export default MCPDashboard
