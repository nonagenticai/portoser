import { useState } from 'react';
import { useQuery, useMutation } from '@tanstack/react-query';
import api from '../../api/client';
import { X, Plus, Trash2, AlertCircle, CheckCircle, Loader } from 'lucide-react';

export default function DependencyDialog({ serviceName, mode = 'add', onClose, onSuccess }) {
  const [selectedDependency, setSelectedDependency] = useState('');
  const [error, setError] = useState(null);

  // Fetch all services for dependency selection
  const { data: graphData } = useQuery({
    queryKey: ['dependency-graph'],
    queryFn: async () => {
      const response = await api.get(`/dependencies/graph`);
      return response.data;
    },
  });

  // Fetch current dependencies
  const { data: currentDeps } = useQuery({
    queryKey: ['service-dependencies', serviceName],
    queryFn: async () => {
      const response = await api.get(`/dependencies/service/${serviceName}`);
      return response.data;
    },
  });

  // Add dependency mutation
  const addMutation = useMutation({
    mutationFn: async (dependency) => {
      const response = await api.post(`/dependencies/add`, {
        service: serviceName,
        dependency: dependency,
      });
      return response.data;
    },
    onSuccess: () => {
      onSuccess();
    },
    onError: (err) => {
      setError(err.response?.data?.detail || 'Failed to add dependency');
    },
  });

  // Remove dependency mutation
  const removeMutation = useMutation({
    mutationFn: async (dependency) => {
      const response = await api.delete(`/dependencies/remove`, {
        data: {
          service: serviceName,
          dependency: dependency,
        },
      });
      return response.data;
    },
    onSuccess: () => {
      onSuccess();
    },
    onError: (err) => {
      setError(err.response?.data?.detail || 'Failed to remove dependency');
    },
  });

  const handleAdd = () => {
    if (!selectedDependency) {
      setError('Please select a dependency');
      return;
    }
    setError(null);
    addMutation.mutate(selectedDependency);
  };

  const handleRemove = (dependency) => {
    setError(null);
    removeMutation.mutate(dependency);
  };

  // Get available services (exclude self and existing dependencies)
  const availableServices = graphData?.nodes?.filter(node => {
    if (node.id === serviceName) return false;
    if (currentDeps?.dependencies?.some(dep => dep.name === node.id)) return false;
    return true;
  }) || [];

  const isLoading = addMutation.isPending || removeMutation.isPending;

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg shadow-xl w-full max-w-md overflow-hidden">
        {/* Header */}
        <div className="px-6 py-4 border-b flex items-center justify-between bg-indigo-600">
          <h2 className="text-xl font-semibold text-white">
            {mode === 'add' ? 'Add Dependency' : 'Remove Dependency'}
          </h2>
          <button onClick={onClose} className="text-white hover:text-gray-200">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="p-6">
          {mode === 'add' ? (
            <>
              <div className="mb-4">
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Service: <span className="font-semibold text-indigo-600">{serviceName}</span>
                </label>
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Select Dependency
                </label>
                <select
                  value={selectedDependency}
                  onChange={(e) => setSelectedDependency(e.target.value)}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-indigo-500"
                  disabled={isLoading}
                >
                  <option value="">Choose a service...</option>
                  {availableServices.map((service) => (
                    <option key={service.id} value={service.id}>
                      {service.label} ({service.type} on {service.host})
                    </option>
                  ))}
                </select>
              </div>

              {availableServices.length === 0 && (
                <div className="p-3 bg-yellow-50 border border-yellow-200 rounded-md text-sm text-yellow-800">
                  All services are already dependencies or unavailable.
                </div>
              )}
            </>
          ) : (
            <>
              <div className="mb-4">
                <label className="block text-sm font-medium text-gray-700 mb-2">
                  Current Dependencies for {serviceName}
                </label>
                {currentDeps?.dependencies && currentDeps.dependencies.length > 0 ? (
                  <div className="space-y-2">
                    {currentDeps.dependencies.map((dep) => (
                      <div
                        key={dep.name}
                        className="flex items-center justify-between p-3 bg-gray-50 border border-gray-200 rounded-md"
                      >
                        <div>
                          <div className="font-medium text-sm">{dep.name}</div>
                          <div className="text-xs text-gray-500">
                            {dep.type} on {dep.host}
                          </div>
                        </div>
                        <button
                          onClick={() => handleRemove(dep.name)}
                          disabled={isLoading}
                          className="text-red-600 hover:text-red-700 disabled:opacity-50"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    ))}
                  </div>
                ) : (
                  <div className="p-3 bg-gray-50 border border-gray-200 rounded-md text-sm text-gray-600">
                    No dependencies to remove
                  </div>
                )}
              </div>
            </>
          )}

          {/* Error/Success Messages */}
          {error && (
            <div className="flex items-start gap-2 p-3 bg-red-50 border border-red-200 rounded-md text-sm text-red-800 mb-4">
              <AlertCircle className="w-4 h-4 mt-0.5" />
              <span>{error}</span>
            </div>
          )}

          {(addMutation.isSuccess || removeMutation.isSuccess) && (
            <div className="flex items-start gap-2 p-3 bg-green-50 border border-green-200 rounded-md text-sm text-green-800 mb-4">
              <CheckCircle className="w-4 h-4 mt-0.5" />
              <span>
                {mode === 'add' ? 'Dependency added successfully!' : 'Dependency removed successfully!'}
              </span>
            </div>
          )}

          {/* Validation Info */}
          <div className="p-3 bg-blue-50 border border-blue-200 rounded-md text-sm text-blue-800">
            <div className="font-medium mb-1">Validation</div>
            <ul className="list-disc list-inside space-y-1">
              <li>Circular dependencies will be prevented</li>
              <li>Changes are written to service configuration files</li>
              <li>Graph will update automatically after changes</li>
            </ul>
          </div>
        </div>

        {/* Footer */}
        <div className="px-6 py-4 border-t bg-gray-50 flex justify-end gap-3">
          <button
            onClick={onClose}
            className="px-4 py-2 text-gray-700 border border-gray-300 rounded-md hover:bg-gray-100"
            disabled={isLoading}
          >
            Close
          </button>
          {mode === 'add' && (
            <button
              onClick={handleAdd}
              disabled={isLoading || !selectedDependency}
              className="flex items-center gap-2 px-4 py-2 bg-indigo-600 text-white rounded-md hover:bg-indigo-700 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isLoading ? (
                <>
                  <Loader className="w-4 h-4 animate-spin" />
                  Adding...
                </>
              ) : (
                <>
                  <Plus className="w-4 h-4" />
                  Add Dependency
                </>
              )}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
