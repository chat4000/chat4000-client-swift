import { useState } from 'react';
import { SetupScreen } from './components/SetupScreen';
import { ChatScreen } from './components/ChatScreen';
import { SettingsModal } from './components/SettingsModal';

export default function App() {
  const [isConnected, setIsConnected] = useState(false);
  const [connectionInfo, setConnectionInfo] = useState({ server: '', port: '' });
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);

  const handleConnect = (server: string, port: string, token: string) => {
    setConnectionInfo({ server, port });
    setIsConnected(true);
  };

  const handleDisconnect = () => {
    setIsConnected(false);
    setConnectionInfo({ server: '', port: '' });
    setIsSettingsOpen(false);
  };

  const handleClearChat = () => {
    // In a real app, this would clear the chat messages
    console.log('Chat history cleared');
  };

  return (
    <div className="size-full">
      {!isConnected ? (
        <SetupScreen onConnect={handleConnect} />
      ) : (
        <>
          <ChatScreen
            server={connectionInfo.server}
            port={connectionInfo.port}
            onOpenSettings={() => setIsSettingsOpen(true)}
          />
          <SettingsModal
            isOpen={isSettingsOpen}
            onClose={() => setIsSettingsOpen(false)}
            server={connectionInfo.server}
            port={connectionInfo.port}
            onDisconnect={handleDisconnect}
            onClearChat={handleClearChat}
          />
        </>
      )}
    </div>
  );
}