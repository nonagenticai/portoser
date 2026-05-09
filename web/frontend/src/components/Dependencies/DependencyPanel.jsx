import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import api from '../../api/client';
import { X, ArrowRight, Play, TrendingUp, Plus, Trash2, Loader } from 'lucide-react';
import DeploymentOrder from './DeploymentOrder';
import ImpactAnalysis from './ImpactAnalysis';
import DependencyDialog from './DependencyDialog';

export default function DependencyPanel({ serviceName, onClose }) {
  const [showDeploymentOrder, setShowDeploymentOrder] = useState(false);
  const [showImpactAnalysis, setShowImpactAnalysis] = useState(false);
  const [showAddDialog, setShowAddDialog] = useState(false);

  // Fetch service dependencies
  const { data: depData, isLoading, refetch } = useQuery({
    queryKey: ['service-dependencies', serviceName],
    queryFn: async () => {
      const response = await api.get(`/dependencies/service/${serviceName}`);
      return response.data;
    },
    enabled: !!serviceName,
  });

  if (isLoading) {
    return (
      <div className="w-96 bg-white border-l flex items-center justify-center">
        <Loader className="w-8 h-8 animate-spin text-indigo-600" />
      </div>
    );
  }

  return (
    <>
      <div className="w-96 bg-white border-l flex flex-col overflow-hidden">
        {/* Header */}
        <div className="px-6 py-4 border-b flex items-center justify-between bg-gray-50">
          <h2 className="text-lg font-semibold text-gray-900">{serviceName}</h2>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-6 space-y-6">
          {/* Dependencies Section */}
          <div>
            <div className="flex items-center justify-between mb-3">
              <h3 className="text-sm font-medium text-gray-700">Dependencies</h3>
              <button
                onClick={() => setShowAddDialog(true)}
                className="text-indigo-600 hover:text-indigo-700"
              >
                <Plus className="w-4 h-4" />
              </button>
            </div>
            {depData?.dependencies && depData.dependencies.length > 0 ? (
              <div className="space-y-2">
                {depData.dependencies.map((dep) => (
                  <div
                    key={dep.name}
                    className="flex items-center justify-between p-3 bg-gray-50 rounded-md"
                  >
                    <div>
                      <div className="font-medium text-sm">{dep.name}</div>
                      <div className="text-xs text-gray-500">
                        {dep.type} on {dep.host}
                      </div>
                    </div>
                    <ArrowRight className="w-4 h-4 text-gray-400" />
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-sm text-gray-500 italic">No dependencies</p>
            )}
          </div>

          {/* Dependents Section */}
          <div>
            <h3 className="text-sm font-medium text-gray-700 mb-3">
              Dependents ({depData?.dependents?.length || 0})
            </h3>
            {depData?.dependents && depData.dependents.length > 0 ? (
              <div className="space-y-2">
                {depData.dependents.map((dep) => (
                  <div
                    key={dep.name}
                    className="flex items-center justify-between p-3 bg-blue-50 rounded-md"
                  >
                    <div>
                      <div className="font-medium text-sm">{dep.name}</div>
                      <div className="text-xs text-gray-500">
                        {dep.type} on {dep.host}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-sm text-gray-500 italic">No services depend on this</p>
            )}
          </div>

          {/* Dependency Chain Visualization */}
          {depData?.dependencies && depData.dependencies.length > 0 && (
            <div className="bg-indigo-50 p-4 rounded-md">
              <h3 className="text-sm font-medium text-indigo-900 mb-3">Dependency Chain</h3>
              <div className="space-y-2">
                <div className="flex items-center gap-2 text-sm">
                  <div className="font-semibold text-indigo-900">{serviceName}</div>
                </div>
                {depData.dependencies.map((dep, index) => (
                  <div key={dep.name} className="flex items-start gap-2 pl-4">
                    <div className="text-indigo-400 mt-1">↓</div>
                    <div className="text-sm text-gray-700">{dep.name}</div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Actions */}
        <div className="px-6 py-4 border-t bg-gray-50 space-y-2">
          <button
            onClick={() => setShowDeploymentOrder(true)}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-indigo-600 text-white rounded-md hover:bg-indigo-700"
          >
            <Play className="w-4 h-4" />
            View Deployment Order
          </button>

          <button
            onClick={() => setShowImpactAnalysis(true)}
            className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-white text-indigo-600 border border-indigo-600 rounded-md hover:bg-indigo-50"
          >
            <TrendingUp className="w-4 h-4" />
            Impact Analysis
          </button>
        </div>
      </div>

      {/* Modals */}
      {showDeploymentOrder && (
        <DeploymentOrder
          serviceName={serviceName}
          onClose={() => setShowDeploymentOrder(false)}
        />
      )}

      {showImpactAnalysis && (
        <ImpactAnalysis
          serviceName={serviceName}
          onClose={() => setShowImpactAnalysis(false)}
        />
      )}

      {showAddDialog && (
        <DependencyDialog
          serviceName={serviceName}
          mode="add"
          onClose={() => setShowAddDialog(false)}
          onSuccess={() => {
            setShowAddDialog(false);
            refetch();
          }}
        />
      )}
    </>
  );
}
