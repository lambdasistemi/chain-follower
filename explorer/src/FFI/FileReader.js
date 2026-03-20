export const readFileAsText = (file) => () =>
  new Promise((resolve, reject) => {
    var reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsText(file);
  });

export const getFilesFromEvent = (event) => () => {
  var input = event.target;
  if (!input || !input.files) return [];
  return Array.from(input.files);
};

export const fileName = (file) => file.name;
