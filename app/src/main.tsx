import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, Routes, Route } from "react-router-dom";
import { I18nProvider } from "./i18n";
import Layout from "./components/Layout";
import Home from "./pages/Home";
import Mining from "./pages/Mining";
import Tasks from "./pages/Tasks";
import Agents from "./pages/Agents";
import Docs from "./pages/Docs";
import Faq from "./pages/Faq";
import NotFound from "./pages/NotFound";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <I18nProvider>
      <BrowserRouter>
        <Routes>
          <Route element={<Layout />}>
            <Route index element={<Home />} />
            <Route path="mining" element={<Mining />} />
            <Route path="tasks" element={<Tasks />} />
            <Route path="agents" element={<Agents />} />
            <Route path="docs" element={<Docs />} />
            <Route path="faq" element={<Faq />} />
            <Route path="*" element={<NotFound />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </I18nProvider>
  </StrictMode>,
);
