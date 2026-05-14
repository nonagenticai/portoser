import { useQuery } from '@tanstack/react-query';
import api from '../../api/client';
import { X, AlertTriangle, TrendingUp, Loader } from 'lucide-react';

const impactColors = {
  low: { bg: 'bg-green-50', text: 'text-green-700', border: 'border-green-200' },
  medium: { bg: 'bg-yellow-50', text: 'text-yellow-700', border: 'border-yellow-200' },
  high: { bg: 'bg-red-50', text: 'text-red-700', border: 'border-red-200' },
};

export default function ImpactAnalysis({ serviceName, onClose }) {
  const { data, isLoading } = useQuery({
    queryKey: ['impact-analysis', serviceName],
    queryFn: async () => {
      const response = await api.get(`/dependencies/impact/${serviceName}`);
      return response.data;
    },
  });

  const colors = impactColors[data?.impact_level] || impactColors.low;

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg shadow-xl w-full max-w-2xl max-h-[80vh] overflow-hidden">
        {/* Header */}
        <div className="px-6 py-4 border-b flex items-center justify-between bg-linear-to-r from-purple-600 to-pink-600">
          <h2 className="text-xl font-semibold text-white">Impact Analysis</h2>
          <button onClick={onClose} className="text-white hover:text-gray-200">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Content */}
        <div className="p-6">
          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader className="w-8 h-8 animate-spin text-purple-600" />
            </div>
          ) : (
            <>
              {/* Impact Level Badge */}
              <div className={`inline-flex items-center gap-2 px-4 py-2 rounded-full ${colors.bg} ${colors.border} border-2 mb-6`}>
                <TrendingUp className={`w-5 h-5 ${colors.text}`} />
                <span className={`font-semibold ${colors.text} uppercase`}>
                  {data?.impact_level} Impact
                </span>
              </div>

              <div className="mb-6">
                <p className="text-gray-600">
                  If <span className="font-semibold text-purple-600">{serviceName}</span> goes down,
                  it will affect <span className="font-semibold">{data?.total_affected || 0}</span> service(s).
                </p>
              </div>

              {/* Direct Dependents */}
              {data?.direct_dependents && data.direct_dependents.length > 0 && (
                <div className="mb-6">
                  <h3 className="text-sm font-semibold text-gray-700 mb-3">
                    Direct Dependents ({data.direct_dependents.length})
                  </h3>
                  <div className="space-y-2">
                    {data.direct_dependents.map((service) => (
                      <div
                        key={service}
                        className="flex items-center gap-3 p-3 bg-red-50 border border-red-200 rounded-md"
                      >
                        <AlertTriangle className="w-4 h-4 text-red-600" />
                        <span className="font-medium text-gray-900">{service}</span>
                        <span className="text-sm text-gray-500">will fail immediately</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* All Affected Services */}
              {data?.all_dependents && data.all_dependents.length > data.direct_dependents?.length && (
                <div>
                  <h3 className="text-sm font-semibold text-gray-700 mb-3">
                    All Affected Services ({data.all_dependents.length})
                  </h3>
                  <div className="grid grid-cols-2 gap-2">
                    {data.all_dependents.map((service) => (
                      <div
                        key={service}
                        className="p-2 bg-orange-50 border border-orange-200 rounded text-sm"
                      >
                        {service}
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Recommendations */}
              {data?.impact_level === 'high' && (
                <div className="mt-6 p-4 bg-red-50 border-2 border-red-200 rounded-lg">
                  <div className="flex items-start gap-2">
                    <AlertTriangle className="w-5 h-5 text-red-600 mt-0.5" />
                    <div>
                      <div className="font-semibold text-red-900 mb-1">Critical Service Warning</div>
                      <div className="text-sm text-red-800">
                        This is a critical service with many dependents. Consider:
                        <ul className="list-disc list-inside mt-2 space-y-1">
                          <li>Implementing high availability (HA) setup</li>
                          <li>Setting up monitoring and alerts</li>
                          <li>Creating backup/failover instances</li>
                          <li>Documenting recovery procedures</li>
                        </ul>
                      </div>
                    </div>
                  </div>
                </div>
              )}

              {data?.total_affected === 0 && (
                <div className="p-4 bg-green-50 border border-green-200 rounded-lg text-green-800">
                  No services depend on this service. It can be safely stopped without affecting others.
                </div>
              )}
            </>
          )}
        </div>

        {/* Footer */}
        <div className="px-6 py-4 border-t bg-gray-50 flex justify-end">
          <button
            onClick={onClose}
            className="px-4 py-2 bg-gray-200 text-gray-700 rounded-md hover:bg-gray-300"
          >
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
