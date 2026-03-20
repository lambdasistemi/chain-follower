var _cy = null;
var _expandCollapse = null;

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
          "font-size": "11px",
          "background-color": "#4a90d9",
          color: "#fff",
          "text-outline-color": "#4a90d9",
          "text-outline-width": 2,
          width: "label",
          height: "label",
          padding: "8px",
          shape: "round-rectangle",
        },
      },
      {
        selector: "node.module",
        style: {
          "background-color": "#2c3e50",
          "text-outline-color": "#2c3e50",
          "font-size": "14px",
          "font-weight": "bold",
          shape: "round-rectangle",
        },
      },
      {
        selector: "node.type",
        style: {
          "background-color": "#8e44ad",
          "text-outline-color": "#8e44ad",
          "font-size": "12px",
          shape: "diamond",
        },
      },
      {
        selector: "node.function",
        style: {
          "background-color": "#27ae60",
          "text-outline-color": "#27ae60",
          "font-size": "10px",
          shape: "ellipse",
        },
      },
      {
        selector: "node.constructor",
        style: {
          "background-color": "#e67e22",
          "text-outline-color": "#e67e22",
          "font-size": "9px",
          shape: "rectangle",
        },
      },
      {
        selector: ":parent",
        style: {
          "background-opacity": 0.1,
          "border-width": 2,
          "border-color": "#555",
          "text-valign": "top",
          "text-halign": "center",
          "font-size": "14px",
          padding: "20px",
        },
      },
      {
        selector: "edge",
        style: {
          width: 1.5,
          "line-color": "#888",
          "target-arrow-color": "#888",
          "target-arrow-shape": "triangle",
          "curve-style": "bezier",
          "arrow-scale": 0.8,
        },
      },
      {
        selector: "edge.type-edge",
        style: {
          "line-style": "dashed",
          "line-color": "#b07cd8",
          "target-arrow-color": "#b07cd8",
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
          "line-color": "#e74c3c",
          "target-arrow-color": "#e74c3c",
          width: 3,
        },
      },
      {
        selector: ".dimmed",
        style: {
          opacity: 0.2,
        },
      },
    ],
    layout: { name: "preset" },
    wheelSensitivity: 0.3,
  });

  // Run elk layout
  _cy.layout({
    name: "elk",
    elk: {
      algorithm: "layered",
      "elk.direction": "DOWN",
      "elk.layered.spacing.nodeNodeBetweenLayers": "80",
      "elk.spacing.nodeNode": "40",
      "elk.hierarchyHandling": "INCLUDE_CHILDREN",
    },
    fit: true,
    padding: 30,
  }).run();

  // Initialize expand-collapse
  _expandCollapse = _cy.expandCollapse({
    layoutBy: {
      name: "elk",
      elk: {
        algorithm: "layered",
        "elk.direction": "DOWN",
        "elk.hierarchyHandling": "INCLUDE_CHILDREN",
      },
      fit: true,
      padding: 30,
    },
    fisheye: false,
    animate: true,
    animationDuration: 300,
    undoable: false,
  });
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
    fit: { eles: node.neighborhood().add(node), padding: 50 },
    duration: 300,
  });
};

export const fitAll = () => {
  if (!_cy) return;
  _cy.animate({ fit: { padding: 30 }, duration: 300 });
};

export const collapseNode = (nodeId) => () => {
  if (!_cy || !_expandCollapse) return;
  var node = _cy.getElementById(nodeId);
  if (node.nonempty() && node.isParent()) {
    _expandCollapse.collapse(node);
  }
};

export const expandNode = (nodeId) => () => {
  if (!_cy || !_expandCollapse) return;
  var node = _cy.getElementById(nodeId);
  if (node.nonempty()) {
    _expandCollapse.expand(node);
  }
};

export const collapseAll = () => {
  if (!_cy || !_expandCollapse) return;
  _expandCollapse.collapseAll();
};

export const expandAll = () => {
  if (!_cy || !_expandCollapse) return;
  _expandCollapse.expandAll();
};

