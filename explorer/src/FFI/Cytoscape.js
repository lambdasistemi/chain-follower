var _cy = null;

export const initCytoscape = (containerId) => (elements) => () => {
  var container = document.getElementById(containerId);
  if (!container) return;

  if (_cy) {
    _cy.destroy();
    _cy = null;
  }

  _cy = cytoscape({
    container: container,
    elements: elements,
    style: [
      {
        selector: "node",
        style: {
          label: "data(label)",
          "text-valign": "center",
          "text-halign": "center",
          "font-size": "10px",
          "background-color": "#4a90d9",
          color: "#fff",
          "text-outline-color": "#4a90d9",
          "text-outline-width": 1.5,
          width: "label",
          height: "label",
          padding: "6px",
          shape: "round-rectangle",
        },
      },
      {
        selector: "node.type",
        style: {
          "background-color": "#8e44ad",
          "text-outline-color": "#8e44ad",
          "font-size": "12px",
          "font-weight": "bold",
          shape: "diamond",
          padding: "10px",
        },
      },
      {
        selector: "node.function",
        style: {
          "background-color": "#27ae60",
          "text-outline-color": "#27ae60",
          shape: "ellipse",
        },
      },
      {
        selector: "node.constructor",
        style: {
          "background-color": "#e67e22",
          "text-outline-color": "#e67e22",
          shape: "rectangle",
          "font-size": "9px",
        },
      },
      {
        selector: "node.field",
        style: {
          "background-color": "#3498db",
          "text-outline-color": "#3498db",
          shape: "round-rectangle",
          "font-size": "8px",
        },
      },
      {
        selector: "edge",
        style: {
          width: 1,
          "line-color": "#555",
          "target-arrow-color": "#555",
          "target-arrow-shape": "triangle",
          "curve-style": "bezier",
          "arrow-scale": 0.7,
          opacity: 0.6,
        },
      },
      {
        selector: "edge.type-edge",
        style: {
          "line-style": "dotted",
          "line-color": "#7f4a9e",
          "target-arrow-color": "#7f4a9e",
          opacity: 0.3,
        },
      },
      {
        selector: "node:selected",
        style: {
          "border-width": 3,
          "border-color": "#e74c3c",
        },
      },
      {
        selector: ".highlighted",
        style: {
          "background-color": "#e74c3c",
          "text-outline-color": "#e74c3c",
          "line-color": "#e74c3c",
          "target-arrow-color": "#e74c3c",
          width: 2.5,
          opacity: 1,
        },
      },
      {
        selector: ".dimmed",
        style: {
          opacity: 0.1,
        },
      },
    ],
    layout: { name: "preset" },
    wheelSensitivity: 0.3,
  });

  // Run ELK layered layout — flat, no compounds
  _cy.layout({
    name: "elk",
    elk: {
      algorithm: "layered",
      "elk.direction": "DOWN",
      "elk.layered.spacing.nodeNodeBetweenLayers": "60",
      "elk.spacing.nodeNode": "30",
    },
    fit: true,
    padding: 40,
  }).run();
};

export const onNodeTap = (callback) => () => {
  if (!_cy) return;
  _cy.on("tap", "node", function (evt) {
    var node = evt.target;
    callback(node.id())(node.data())();
  });
};

export const onNodeDoubleTap = (callback) => () => {
  if (!_cy) return;
  _cy.on("dbltap", "node", function (evt) {
    var node = evt.target;
    callback(node.id())();
  });
};

export const highlightNeighborhood = (nodeId) => () => {
  if (!_cy) return;
  _cy.elements().removeClass("highlighted dimmed");
  var node = _cy.getElementById(nodeId);
  if (node.empty()) return;
  var neighborhood = node.neighborhood().add(node);
  _cy.elements().not(neighborhood).addClass("dimmed");
  neighborhood.addClass("highlighted");
};

export const clearHighlight = () => {
  if (!_cy) return;
  _cy.elements().removeClass("highlighted dimmed");
};

export const fitToNode = (nodeId) => () => {
  if (!_cy) return;
  var node = _cy.getElementById(nodeId);
  if (node.empty()) return;
  _cy.animate({
    fit: {
      eles: node.neighborhood().add(node),
      padding: 50,
    },
    duration: 300,
  });
};

export const fitAll = () => {
  if (!_cy) return;
  _cy.animate({ fit: { padding: 30 }, duration: 300 });
};

export const collapseNode = (_nodeId) => () => {};
export const expandNode = (_nodeId) => () => {};
export const collapseAll = () => {};
export const expandAll = () => {};
