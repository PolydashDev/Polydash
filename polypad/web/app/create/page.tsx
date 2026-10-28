import { Header } from '@/components/header';
import { Footer } from '@/components/footer';
import { CreateWizard } from './_components/create-wizard';

export default function CreatePage() {
  return (
    <div className="min-h-screen flex flex-col bg-background">
      <Header />
      <main className="flex-1">
        <CreateWizard />
      </main>
      <Footer />
    </div>
  );
}
