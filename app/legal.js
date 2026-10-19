// Preenche dados da empresa e monta o índice das páginas legais
(function () {
  const E = window.PULSE_EMPRESA || {};
  const marca = E.marca || "Pulse Medcards";
  const nomes = (E.responsaveis || []).filter(Boolean);
  const listaNomes = nomes.length > 1 ? nomes.slice(0, -1).join(", ") + " e " + nomes.at(-1) : nomes[0];
  const controlador = E.razaoSocial
    ? `${E.razaoSocial}${E.cnpj ? `, inscrita no CNPJ sob o nº ${E.cnpj}` : ""}${E.cidadeUf ? `, com sede em ${E.cidadeUf}` : ""}`
    : nomes.length
      ? `${listaNomes}, ${nomes.length > 1 ? "pessoas físicas" : "pessoa física"}${E.cidadeUf ? `, em ${E.cidadeUf}` : ""}`
      : marca;
  const papel = !E.razaoSocial && nomes.length > 1 ? "os controladores" : "o controlador";
  const valores = { marca, controlador, papel, vigencia: E.vigencia || "", versao: E.versao || "", email: E.emailContato || "", encarregado: E.encarregado || "" };
  document.querySelectorAll("[data-e]").forEach((el) => {
    const v = valores[el.dataset.e];
    if (el.dataset.e === "email" && v) { const a = document.createElement("a"); a.href = "mailto:" + v; a.textContent = v; el.replaceChildren(a); }
    else if (v) el.textContent = v;
  });
  // Blocos que dependem de um campo: data-se="email" só aparece se houver e-mail; data-senao="email" o contrário
  document.querySelectorAll("[data-se]").forEach((el) => { el.hidden = !valores[el.dataset.se]; });
  document.querySelectorAll("[data-senao]").forEach((el) => { el.hidden = !!valores[el.dataset.senao]; });

  // Índice a partir das seções numeradas
  const nav = document.getElementById("lista-indice");
  if (nav) document.querySelectorAll("main section[id] > h2").forEach((h) => {
    const a = document.createElement("a");
    a.href = "#" + h.parentElement.id;
    const n = h.querySelector(".n")?.textContent ?? "";
    const titulo = [...h.childNodes].filter((x) => !(x.classList && x.classList.contains("n"))).map((x) => x.textContent).join("").trim();
    a.innerHTML = `<span class="n-ind"></span>`; a.firstChild.textContent = n; a.append(titulo);
    nav.appendChild(a);
  });
  // No celular, o índice começa recolhido
  const det = document.querySelector(".indice details");
  if (det && matchMedia("(max-width: 899px)").matches) det.open = false;
  document.getElementById("ano").textContent = new Date().getFullYear();
})();
