import React, { useState, useEffect } from 'react';
import api from '../api/client';
import { Clock, CheckCircle, XCircle, RotateCcw, Search, Calendar, TrendingUp, AlertTriangle } from 'lucide-react';
import { safeToFixed } from '../utils/formatters';

const DeploymentHistory = () => {
  const [deployments, setDeployments] = useState([]);
  const [stats, setStats] = useState(null);
  const [selectedDeployment, setSelectedDeployment] = useState(null);
  const [rollbackPreview, setRollbackPreview] = useState(null);
  const [loading, setLoading] = useState(true);
  const [filters, setFilters] = useState({
    service: '',
    machine: '',
    status: '',
    limit: 50
  });

  useEffect(() => {
    fetchDeployments();
    fetchStats();
  }, [filters]);

  const fetchDeployments = async () => {
    try {
      const params = new URLSearchParams();
      if (filters.service) params.append('service', filters.service);
      if (filters.machine) params.append('machine', filters.machine);
      if (filters.status) params.append('status', filters.status);
      params.append('limit', filters.limit);

      const response = await api.get(`/history/deployments?${params}`);
      setDeployments(response.data.deployments);
      setLoading(false);
    } catch (error) {
      console.error('Failed to fetch deployments:', error);
      setLoading(false);
    }
  };

  const fetchStats = async () => {
    try {
      const params = filters.service ? `?service=${filters.service}` : '';
      const response = await api.get(`/history/stats${params}`);
      setStats(response.data);
    } catch (error) {
      console.error('Failed to fetch stats:', error);
    }
  };

  const viewDetails = async (deploymentId) => {
    try {
      const response = await api.get(`/history/deployments/${deploymentId}`);
      setSelectedDeployment(response.data);
    } catch (error) {
      console.error('Failed to fetch deployment details:', error);
    }
  };

  const previewRollback = async (deploymentId) => {
    try {
      const response = await api.get(`/history/rollback/${deploymentId}/preview`);
      setRollbackPreview(response.data);
    } catch (error) {
      console.error('Failed to fetch rollback preview:', error);
    }
  };

  const executeRollback = async (deploymentId) => {
    if (!confirm('Are you sure you want to rollback to this deployment?')) return;

    try {
      const response = await api.post(`/history/rollback/${deploymentId}`, {
        confirm: true,
        dry_run: false
      });

      if (response.data.success) {
        alert('Rollback completed successfully!');
        fetchDeployments();
        setRollbackPreview(null);
      } else {
        alert(`Rollback failed: ${response.data.error}`);
      }
    } catch (error) {
      console.error('Rollback failed:', error);
      alert('Rollback failed: ' + error.message);
    }
  };

  const formatDuration = (ms) => {
    const seconds = Math.floor(ms / 1000);
    if (seconds < 60) return `${seconds}s`;
    const minutes = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${minutes}m ${secs}s`;
  };

  const formatTimestamp = (timestamp) => {
    const date = new Date(timestamp);
    const now = new Date();
    const diff = now - date;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(diff / 3600000);
    const days = Math.floor(diff / 86400000);

    if (minutes < 60) return `${minutes}m ago`;
    if (hours < 24) return `${hours}h ago`;
    if (days < 7) return `${days}d ago`;
    return date.toLocaleDateString();
  };

  const StatusBadge = ({ status }) => {
    const config = {
      success: { icon: CheckCircle, color: 'text-green-600 bg-green-50', label: 'Success' },
      failure: { icon: XCircle, color: 'text-red-600 bg-red-50', label: 'Failed' },
      rolled_back: { icon: RotateCcw, color: 'text-yellow-600 bg-yellow-50', label: 'Rolled Back' }
    };

    const { icon: Icon, color, label } = config[status] || config.success;

    return (
      <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${color}`}>
        <Icon className="w-3 h-3 mr-1" />
        {label}
      </span>
    );
  };

  return (
    <div className="min-h-screen bg-gray-50 p-6">
      <div className="max-w-7xl mx-auto">
        {/* Header */}
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-3">
            <Clock className="w-8 h-8 text-blue-600" />
            <h1 className="text-3xl font-bold text-gray-900">Deployment History</h1>
          </div>
        </div>

        {/* Stats Cards */}
        {stats && (
          <div className="grid grid-cols-4 gap-4 mb-6">
            <div className="bg-white p-4 rounded-lg shadow">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm text-gray-600">Total Deployments</p>
                  <p className="text-2xl font-bold">{stats.total}</p>
                </div>
                <TrendingUp className="w-8 h-8 text-blue-500" />
              </div>
            </div>
            <div className="bg-white p-4 rounded-lg shadow">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm text-gray-600">Success Rate</p>
                  <p className="text-2xl font-bold">{safeToFixed(stats.success_rate, 1)}%</p>
                </div>
                <CheckCircle className="w-8 h-8 text-green-500" />
              </div>
            </div>
            <div className="bg-white p-4 rounded-lg shadow">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm text-gray-600">Failures</p>
                  <p className="text-2xl font-bold">{stats.failure}</p>
                </div>
                <XCircle className="w-8 h-8 text-red-500" />
              </div>
            </div>
            <div className="bg-white p-4 rounded-lg shadow">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm text-gray-600">Avg Duration</p>
                  <p className="text-2xl font-bold">{formatDuration(stats.avg_duration_ms)}</p>
                </div>
                <Clock className="w-8 h-8 text-purple-500" />
              </div>
            </div>
          </div>
        )}

        {/* Filters */}
        <div className="bg-white p-4 rounded-lg shadow mb-6">
          <div className="grid grid-cols-4 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Service</label>
              <input
                type="text"
                value={filters.service}
                onChange={(e) => setFilters({...filters, service: e.target.value})}
                className="w-full px-3 py-2 border rounded-md"
                placeholder="Filter by service..."
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Machine</label>
              <input
                type="text"
                value={filters.machine}
                onChange={(e) => setFilters({...filters, machine: e.target.value})}
                className="w-full px-3 py-2 border rounded-md"
                placeholder="Filter by machine..."
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Status</label>
              <select
                value={filters.status}
                onChange={(e) => setFilters({...filters, status: e.target.value})}
                className="w-full px-3 py-2 border rounded-md"
              >
                <option value="">All</option>
                <option value="success">Success</option>
                <option value="failure">Failure</option>
                <option value="rolled_back">Rolled Back</option>
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Limit</label>
              <select
                value={filters.limit}
                onChange={(e) => setFilters({...filters, limit: parseInt(e.target.value)})}
                className="w-full px-3 py-2 border rounded-md"
              >
                <option value="20">20</option>
                <option value="50">50</option>
                <option value="100">100</option>
              </select>
            </div>
          </div>
        </div>

        {/* Deployments List */}
        <div className="bg-white rounded-lg shadow overflow-hidden">
          {loading ? (
            <div className="p-8 text-center text-gray-500">Loading...</div>
          ) : deployments.length === 0 ? (
            <div className="p-8 text-center text-gray-500">No deployments found</div>
          ) : (
            <div className="divide-y">
              {deployments.map((deployment) => (
                <div key={deployment.id} className="p-4 hover:bg-gray-50 transition-colors">
                  <div className="flex items-center justify-between">
                    <div className="flex-1">
                      <div className="flex items-center gap-3 mb-2">
                        <h3 className="text-lg font-semibold text-gray-900">{deployment.service}</h3>
                        <span className="text-sm text-gray-500">→</span>
                        <span className="text-sm font-medium text-gray-700">{deployment.machine}</span>
                        <StatusBadge status={deployment.status} />
                      </div>
                      <div className="flex items-center gap-4 text-sm text-gray-600">
                        <span className="flex items-center gap-1">
                          <Clock className="w-4 h-4" />
                          {formatTimestamp(deployment.timestamp)}
                        </span>
                        <span>Duration: {formatDuration(deployment.duration_ms)}</span>
                        <span>Action: {deployment.action}</span>
                        {deployment.problems.length > 0 && (
                          <span className="flex items-center gap-1 text-yellow-600">
                            <AlertTriangle className="w-4 h-4" />
                            {deployment.problems.length} problems
                          </span>
                        )}
                      </div>
                    </div>
                    <div className="flex gap-2">
                      <button
                        onClick={() => viewDetails(deployment.id)}
                        className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700"
                      >
                        View Details
                      </button>
                      {deployment.status === 'success' && (
                        <button
                          onClick={() => previewRollback(deployment.id)}
                          className="px-4 py-2 bg-yellow-600 text-white rounded-md hover:bg-yellow-700 flex items-center gap-2"
                        >
                          <RotateCcw className="w-4 h-4" />
                          Rollback
                        </button>
                      )}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Details Modal */}
        {selectedDeployment && (
          <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
            <div className="bg-white rounded-lg max-w-4xl w-full max-h-[90vh] overflow-y-auto">
              <div className="p-6 border-b">
                <div className="flex items-center justify-between">
                  <h2 className="text-2xl font-bold">Deployment Details</h2>
                  <button
                    onClick={() => setSelectedDeployment(null)}
                    className="text-gray-400 hover:text-gray-600"
                  >
                    ✕
                  </button>
                </div>
                <p className="text-sm text-gray-600 mt-1">{selectedDeployment.id}</p>
              </div>
              <div className="p-6">
                <div className="grid grid-cols-2 gap-4 mb-6">
                  <div>
                    <p className="text-sm text-gray-600">Service</p>
                    <p className="font-semibold">{selectedDeployment.service}</p>
                  </div>
                  <div>
                    <p className="text-sm text-gray-600">Machine</p>
                    <p className="font-semibold">{selectedDeployment.machine}</p>
                  </div>
                  <div>
                    <p className="text-sm text-gray-600">Status</p>
                    <StatusBadge status={selectedDeployment.status} />
                  </div>
                  <div>
                    <p className="text-sm text-gray-600">Duration</p>
                    <p className="font-semibold">{formatDuration(selectedDeployment.duration_ms)}</p>
                  </div>
                </div>

                {selectedDeployment.phases.length > 0 && (
                  <div className="mb-6">
                    <h3 className="font-semibold mb-2">Phases</h3>
                    <div className="space-y-2">
                      {selectedDeployment.phases.map((phase, idx) => (
                        <div key={idx} className="p-3 bg-gray-50 rounded">
                          <div className="flex items-center justify-between">
                            <span className="font-medium">{phase.name}</span>
                            <span className="text-sm text-gray-600">
                              {formatDuration(phase.duration_ms)}
                            </span>
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>
                )}

                {selectedDeployment.problems.length > 0 && (
                  <div className="mb-6">
                    <h3 className="font-semibold mb-2">Problems Detected</h3>
                    <div className="space-y-2">
                      {selectedDeployment.problems.map((problem, idx) => (
                        <div key={idx} className="p-3 bg-red-50 rounded">
                          <p className="text-sm font-medium text-red-900">{problem.fingerprint}</p>
                          <p className="text-sm text-red-700">{problem.description}</p>
                        </div>
                      ))}
                    </div>
                  </div>
                )}

                {selectedDeployment.solutions_applied.length > 0 && (
                  <div className="mb-6">
                    <h3 className="font-semibold mb-2">Solutions Applied</h3>
                    <div className="space-y-2">
                      {selectedDeployment.solutions_applied.map((solution, idx) => (
                        <div key={idx} className="p-3 bg-green-50 rounded">
                          <p className="text-sm font-medium text-green-900">{solution.action}</p>
                          <p className="text-sm text-green-700">{solution.result}</p>
                        </div>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            </div>
          </div>
        )}

        {/* Rollback Preview Modal */}
        {rollbackPreview && (
          <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
            <div className="bg-white rounded-lg max-w-3xl w-full max-h-[90vh] overflow-y-auto">
              <div className="p-6 border-b">
                <div className="flex items-center justify-between">
                  <h2 className="text-2xl font-bold">Rollback Preview</h2>
                  <button
                    onClick={() => setRollbackPreview(null)}
                    className="text-gray-400 hover:text-gray-600"
                  >
                    ✕
                  </button>
                </div>
              </div>
              <div className="p-6">
                <div className="mb-6">
                  <h3 className="font-semibold mb-2">Service: {rollbackPreview.service}</h3>
                  <p className="text-sm text-gray-600">Machine: {rollbackPreview.machine}</p>
                </div>

                {rollbackPreview.warnings.length > 0 && (
                  <div className="mb-6 p-4 bg-yellow-50 rounded-lg">
                    <h3 className="font-semibold text-yellow-900 mb-2">Warnings</h3>
                    <ul className="list-disc list-inside text-sm text-yellow-700">
                      {rollbackPreview.warnings.map((warning, idx) => (
                        <li key={idx}>{warning}</li>
                      ))}
                    </ul>
                  </div>
                )}

                {rollbackPreview.differences.length > 0 && (
                  <div className="mb-6">
                    <h3 className="font-semibold mb-2">Configuration Changes</h3>
                    <div className="space-y-2">
                      {rollbackPreview.differences.map((diff, idx) => (
                        <div key={idx} className="p-3 bg-gray-50 rounded">
                          <p className="text-sm font-medium">{diff.field}</p>
                          <div className="text-sm text-gray-600 mt-1">
                            <span className="text-red-600">- {JSON.stringify(diff.current_value)}</span>
                            <br />
                            <span className="text-green-600">+ {JSON.stringify(diff.target_value)}</span>
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>
                )}

                <div className="flex gap-3">
                  <button
                    onClick={() => setRollbackPreview(null)}
                    className="flex-1 px-4 py-2 border border-gray-300 rounded-md hover:bg-gray-50"
                  >
                    Cancel
                  </button>
                  <button
                    onClick={() => executeRollback(rollbackPreview.deployment_id)}
                    disabled={!rollbackPreview.safe_to_rollback}
                    className="flex-1 px-4 py-2 bg-yellow-600 text-white rounded-md hover:bg-yellow-700 disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    Confirm Rollback
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

export default DeploymentHistory;
