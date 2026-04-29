import { X } from 'lucide-react';

interface SettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
  server: string;
  port: string;
  onDisconnect: () => void;
  onClearChat: () => void;
}

export function SettingsModal({
  isOpen,
  onClose,
  server,
  port,
  onDisconnect,
  onClearChat
}: SettingsModalProps) {
  if (!isOpen) return null;

  const handleClearChat = () => {
    if (window.confirm('Are you sure you want to clear all chat history? This action cannot be undone.')) {
      onClearChat();
      onClose();
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center"
      style={{ backgroundColor: 'rgba(0, 0, 0, 0.7)' }}
      onClick={onClose}
    >
      <div
        className="w-full max-w-lg rounded-t-3xl p-6 space-y-6 animate-slide-up"
        style={{
          backgroundColor: '#141414',
          maxHeight: '80vh',
          animation: 'slideUp 0.2s ease-out'
        }}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between pb-4" style={{ borderBottom: '1px solid #1E1E1E' }}>
          <h3 className="text-white">Settings</h3>
          <button
            onClick={onClose}
            className="p-2 rounded-lg hover:bg-opacity-10 transition-colors duration-200"
            style={{ color: '#9CA3AF' }}
            onMouseEnter={(e) => e.currentTarget.style.backgroundColor = 'rgba(255, 255, 255, 0.05)'}
            onMouseLeave={(e) => e.currentTarget.style.backgroundColor = 'transparent'}
          >
            <X size={20} />
          </button>
        </div>

        {/* Server Info */}
        <div className="space-y-3">
          <h4 className="text-gray-300" style={{ fontSize: '14px' }}>Connection</h4>
          <div
            className="p-4 rounded-lg"
            style={{
              backgroundColor: '#1A1A1A',
              border: '1px solid #2A2A2A'
            }}
          >
            <div className="space-y-2">
              <div className="flex justify-between">
                <span style={{ fontSize: '13px', color: '#9CA3AF' }}>Server</span>
                <span style={{ fontSize: '13px', color: '#E0E0E0' }}>{server}</span>
              </div>
              <div className="flex justify-between">
                <span style={{ fontSize: '13px', color: '#9CA3AF' }}>Port</span>
                <span style={{ fontSize: '13px', color: '#E0E0E0' }}>{port}</span>
              </div>
            </div>
          </div>
        </div>

        {/* Actions */}
        <div className="space-y-3">
          <button
            onClick={onDisconnect}
            className="w-full py-3 rounded-lg transition-all duration-200 hover:opacity-90"
            style={{
              backgroundColor: '#FF4A4A',
              color: '#ffffff'
            }}
          >
            Disconnect
          </button>

          <button
            onClick={handleClearChat}
            className="w-full py-3 rounded-lg transition-all duration-200"
            style={{
              backgroundColor: '#1A1A1A',
              color: '#E0E0E0',
              border: '1px solid #2A2A2A'
            }}
            onMouseEnter={(e) => e.currentTarget.style.backgroundColor = '#222222'}
            onMouseLeave={(e) => e.currentTarget.style.backgroundColor = '#1A1A1A'}
          >
            Clear Chat History
          </button>
        </div>

        {/* App Version */}
        <div className="pt-4 text-center" style={{ fontSize: '11px', color: '#666666', borderTop: '1px solid #1E1E1E' }}>
          chat4000 v1.0.0
        </div>
      </div>

      <style>{`
        @keyframes slideUp {
          from {
            transform: translateY(100%);
            opacity: 0;
          }
          to {
            transform: translateY(0);
            opacity: 1;
          }
        }
      `}</style>
    </div>
  );
}
