import './globals.css';
import Link from 'next/link';
import { navItems } from '@/lib/nav';

export const metadata = { title: 'Nabuuma Recipe Control', description: 'Hospitality recipe and standards control.' };

export default function RootLayout({children}:{children:React.ReactNode}){
  return <html lang="en"><body><div className="appShell">
    <aside className="sidebar"><div className="logoMark"><span>N</span><div><b>NABUUMA</b><small>RECIPE CONTROL</small></div></div>
      <div className="businessSwitch"><small>WORKSPACE</small><strong>Workspace</strong><span>⌄</span></div>
      <nav>{navItems.map(i=><Link key={i.href} href={i.href}><span className="navIcon">{i.icon}</span>{i.label}</Link>)}</nav>
      <div className="sideBottom"><div className="statusDot">● <span>System ready</span></div></div>
    </aside>
    <main className="content"><header className="mobileHeader"><b>NABUUMA</b><span>Recipe Control</span></header>{children}</main>
  </div></body></html>
}