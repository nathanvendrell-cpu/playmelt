        function subPlanText(plan) {
          if (!plan) return { price: "", unit: "", billing: "" };
          if (!plan.months) return { price: euros(plan.priceCents), unit: "une seule fois", billing: "Accès à vie, mises à jour comprises" };
          if (plan.months === 1) return { price: euros(plan.priceCents), unit: "/ mois", billing: "Facturé chaque mois" };
          return {
            price: euros(plan.monthlyEquivalentCents || plan.priceCents / plan.months),
            unit: "/ mois",
            billing: `${euros(plan.priceCents)} facturés ${plan.months === 12 ? "une fois par an" : `tous les ${plan.months} mois`}`,
          };
        }
        function openSubscription() {
          const sub = state.subscription || {}, body = $("subscriptionBody"), dialog = $("subscriptionDialog");
          dialog.classList.add("sub-sheet");
          $("subscriptionStatus").textContent = String(sub.message || "");
          const plans = Array.isArray(sub.plans) ? sub.plans : [];
          if (!plans.some((p) => p.id === ui.subPlan)) ui.subPlan = (plans.find((p) => p.months === 12) || plans[0] || {}).id;
          body.replaceChildren();

          const top = el("div", "sub-top");
          const close = el("button", "sub-x", "×");
          close.type = "button";
          close.setAttribute("aria-label", "Fermer");
          close.addEventListener("click", () => dialog.close());
          const brand = el("div", "sub-brand");
          const icon = el("img");
          icon.src = "PlaymeltIcon.png";
          icon.alt = "";
          const name = el("div");
          name.append(el("b", "", "Playmelt"), el("small", "", "Toutes tes plateformes. Une seule app."));
          brand.append(icon, name);
          const perks = el("div", "sub-perks");
          for (const perk of ["Jeux Windows sur Mac", "DLSS → MetalFX", "Moteur mis à jour"]) {
            const span = el("span");
            span.innerHTML = ICON.check;
            span.append(document.createTextNode(perk));
            perks.append(span);
          }
          top.append(close, brand, perks);

          const main = el("div", "sub-body");
          main.tabIndex = -1;
          main.autofocus = true;
          if (plans.length) {
            const durs = el("div", "sub-durs");
            const price = el("div", "sub-price");
            const amount = el("b"), unit = el("span");
            price.append(amount, unit);
            const billing = el("div", "sub-billing");
            const paint = () => {
              const plan = plans.find((p) => p.id === ui.subPlan);
              const text = subPlanText(plan);
              amount.textContent = text.price;
              unit.textContent = text.unit;
              billing.textContent = text.billing;
              durs.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b.dataset.plan === ui.subPlan));
            };
            durs.style.gridTemplateColumns = `repeat(${plans.length}, 1fr)`;
            for (const plan of plans) {
              const button = el("button", "", String(plan.label));
              button.type = "button";
              button.dataset.plan = plan.id;
              button.append(el("small", "", plan.savingPercent > 0 ? `−${plan.savingPercent} %` : ""));
              button.addEventListener("click", () => { ui.subPlan = plan.id; paint(); });
              durs.append(button);
            }
            const cta = el("button", "button primary sub-cta", sub.checkoutURL ? "Continuer vers le paiement" : "Bientôt disponible");
            cta.type = "button";
            cta.disabled = !sub.checkoutURL;
            cta.addEventListener("click", () => send("openCheckout", { plan: ui.subPlan }));
            main.append(durs, price, billing, cta);
            paint();
          }

          const fine = el("div", "sub-fine");
          fine.append(el("span", "", "Paiement sécurisé · résiliable à tout moment"));
          const keyToggle = el("button", "", "J’ai une clé de licence");
          keyToggle.type = "button";
          fine.append(keyToggle);
          const keyRow = el("div", "sub-key");
          keyRow.hidden = true;
          const input = el("input");
          input.type = "text";
          input.autocomplete = "off";
          input.spellcheck = false;
          input.maxLength = 128;
          input.placeholder = "Clé reçue par e-mail";
          input.setAttribute("aria-label", "Clé de licence");
          const activate = el("button", "button", "Activer");
          activate.type = "button";
          const submit = () => { const key = input.value.trim(); if (key) send("activateLicense", { key }); };
          activate.addEventListener("click", submit);
          input.addEventListener("keydown", (event) => { if (event.key === "Enter") submit(); });
          keyRow.append(input, activate);
          keyToggle.addEventListener("click", () => { keyRow.hidden = !keyRow.hidden; if (!keyRow.hidden) input.focus(); });
          main.append(fine, keyRow);

          if (sub.allowed && sub.keySuffix) {
            const status = el("div", "sub-status", `Licence active sur ce Mac · clé …${String(sub.keySuffix)}`);
            const remove = el("button", "button", "Retirer ce Mac");
            remove.type = "button";
            remove.addEventListener("click", () => send("deactivateLicense"));
            status.append(remove);
            main.append(status);
          } else if (!sub.allowed && sub.message) {
            main.append(el("div", "sub-status denied", String(sub.message)));
          }
          body.append(top, main);
          if (!dialog.open) dialog.showModal();
        }
