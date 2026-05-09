import { useQuery } from '@tanstack/react-query';
import api from '../../api/client';
import { X, Play, Clock, Loader } from 'lucide-react';

export default function DeploymentOrder({ serviceName, onClose }) {
  const { data, isLoading } = useQuery({
    queryKey: ['deployment-order', serviceName],
    queryFn: async () => {
      const response = await api.get(`/dependencies/deployment-order/${serviceName}`);
      return response.data;
    },
  });

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg shadow-xl w-full max-w-2xl max-h-[80vh] overflow-hidden">
        {/* Header */}
        <div className="px-6 py-4 border-b flex items-center justify-between bg-gradient-to-r from-indigo-600 to-purple-600">
          <h2 className="text-xl font-semibold text-white">Deployment Order</h2>
          <button onClick={onClose} className="text-white hover:text-gray-200">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="p-6">
          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader className="w-8 h-8 animate-spin text-indigo-600" />
            </div>
          ) : (
            <>
              <div className="mb-6">
                <p className="text-gray-600">
                  To deploy <span className="font-semibold text-indigo-600">{serviceName}</span>,
                  services must be started in the following order to respect dependencies:
                </p>
              </div>

              <div className="space-y-3">
                {data?.deployment_order?.map((service, index) => (
                  <div
                    key={service}
                    className={`flex items-center gap-4 p-4 rounded-lg border-2 ${
                      service === serviceName
                        ? 'border-indigo-600 bg-indigo-50'
                        : 'border-gray-200 bg-gray-50'
                    }`}
                  >
                    <div className="flex items-center justify-center w-10 h-10 rounded-full bg-indigo-600 text-white font-bold">
                      {index + 1}
                    </div>
                    <div className="flex-1">
                      <div className="font-semibold text-gray-900">{service}</div>
                      {service === serviceName && (
                        <div className="text-sm text-indigo-600">Target service</div>
                      )}
                    </div>
                    {index < data.deployment_order.length - 1 && (
                      <div className="text-gray-400">→</div>
                    )}
                  </div>
                ))}
              </div>

              <div className="mt-6 p-4 bg-blue-50 rounded-lg">
                <div className="flex items-center gap-2 text-blue-900 mb-2">
                  <Clock className="w-4 h-4" />
                  <span className="font-medium">Deployment Info</span>
                </div>
                <div className="text-sm text-blue-800">
                  Total services to deploy: {data?.total_services || 0}
                </div>
                <div className="text-sm text-blue-800 mt-1">
                  Estimated time: ~{(data?.total_services || 0) * 30}s
                </div>
              </div>
            </>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-4 border-t bg-gray-50 flex justify-end gap-3">
          <button
            onClick={onClose}
            className="px-4 py-2 text-gray-700 border border-gray-300 rounded-md hover:bg-gray-100"
          >
            Close
          </button>
          <button
            className="flex items-center gap-2 px-4 py-2 bg-indigo-600 text-white rounded-md hover:bg-indigo-700"
            disabled={isLoading}
          >
            <Play className="w-4 h-4" />
            Deploy in Order
          </button>
        </div>
      </div>
    </div>
  );
}
